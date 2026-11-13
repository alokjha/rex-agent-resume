-- lib.lua: the parts of rex-agent-resume that don't talk to Rex, so they can be
-- tested with a plain Lua interpreter. Written for Lua 5.1, which Rex embeds.

local M = {}

M.RESTORE_WINDOW = 120 -- seconds after a server starts that panes may be typed into
M.SWEEP = 15           -- seconds between timed sweeps
M.MISSES = 2           -- timed sweeps an agent must be missing from before it's forgotten
M.SHELLS = { zsh = true, bash = true, fish = true }
M.STATE_VERSION = 1

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function M.is_uuid(s)
  return type(s) == "string" and s:find(UUID) ~= nil
end

-- Single-quoted for zsh, bash and fish alike. A backslash inside single quotes
-- means something different to fish, so a string holding one is refused.
function M.sh_quote(s)
  s = tostring(s)
  if s:find("\\", 1, true) then return nil end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- The line that resumes an entry's conversation in its folder, or nil and why.
function M.resume_line(e)
  if type(e) ~= "table" or not M.is_uuid(e.id) then return nil, "its session id isn't a UUID" end
  local cmd
  if e.agent == "claude" then cmd = "claude --resume " .. e.id
  elseif e.agent == "codex" then cmd = "codex resume " .. e.id
  else return nil, "unknown agent " .. tostring(e.agent) end
  if e.cwd then
    local q = M.sh_quote(e.cwd)
    if not q then return nil, "its folder has a backslash" end
    cmd = "cd " .. q .. " && " .. cmd
  end
  return cmd
end

-- What is typed into a pane: Ctrl-U first, which clears anything left on the
-- line in zsh, bash and fish (in emacs and vi insert keys alike), then the line.
function M.restore_input(line)
  return "\21" .. line .. "\r"
end

-- `ps -o etime=` ("[[dd-]hh:]mm:ss") in seconds.
function M.parse_etime(text)
  if type(text) ~= "string" then return nil end
  text = text:match("^%s*(.-)%s*$")
  local days, clock = text:match("^(%d+)%-(.+)$")
  clock = clock or text
  local parts = {}
  for n in clock:gmatch("[^:]+") do
    if not n:find("^%d+$") then return nil end
    parts[#parts + 1] = tonumber(n)
  end
  if #parts < 2 or #parts > 3 or (days and #parts ~= 3) then return nil end
  local h = #parts == 3 and parts[1] or 0
  return (tonumber(days) or 0) * 86400 + h * 3600 + parts[#parts - 1] * 60 + parts[#parts]
end

-- An ISO-8601 UTC time ("2026-11-13T15:58:36.49Z") in Unix seconds.
function M.iso_to_epoch(text)
  if type(text) ~= "string" then return nil end
  local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  if mo <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (mo + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

-- A pane is at its shell when its foreground process is the program Rex
-- started (the terminal's child, often `login`) or that program's child.
function M.at_shell(p)
  if type(p) ~= "table" then return false end
  local fg, child = p.foreground, p.child
  if type(fg) ~= "table" or type(child) ~= "table" or not fg.pid then return false end
  if fg.pid == child.pid then return true end
  local parent = type(p.ancestors) == "table" and p.ancestors[1]
  return type(parent) == "table" and parent.pid == child.pid
end

function M.program(fg)
  if type(fg) ~= "table" then return nil end
  local name = (fg.argv0 or fg.name or ""):match("([^/]+)$") or ""
  return (name:gsub("^%-", ""))
end

-- From `ps -ww -o etime=,args=`: the process's age and its arguments as words.
-- ps joins arguments with spaces, so an argument holding one comes back split.
function M.parse_ps(line)
  if type(line) ~= "string" then return nil end
  local etime, args = line:match("^%s*(%S+)%s+(.-)%s*$")
  local age = M.parse_etime(etime)
  if not age then return nil end
  local words = {}
  for w in args:gmatch("%S+") do words[#words + 1] = w end
  return age, words
end

-- The conversation a codex command line names: `codex [options] resume X`.
-- Returns { uuid = X } or { name = X }, or nil.
function M.codex_target(words)
  if type(words) ~= "table" then return nil end
  for i = 2, #words do
    if words[i] == "resume" then
      local x = words[i + 1]
      if not x or x:sub(1, 1) == "-" then return nil end
      if M.is_uuid(x) then return { uuid = x } end
      return { name = table.concat(words, " ", i + 1) }
    elseif words[i]:sub(1, 1) ~= "-" and words[i - 1]:sub(1, 1) ~= "-" then
      return nil -- another subcommand, or a prompt (a word after an option is its value)
    end
  end
  return nil
end

-- The thread name Codex shows in its title, "NAME | FOLDER", or the title.
function M.codex_title_name(title)
  if type(title) ~= "string" or title == "" then return nil end
  return title:match("^(.-) | [^|]*$") or title
end

-- Picks a Codex TUI's thread from `rows` (Codex's threads in its folder that
-- were written since it started, or that its command line names, newest
-- first). `shared` says another Codex runs in the same folder.
function M.pick_codex_thread(rows, title, target, shared)
  if type(rows) ~= "table" or #rows == 0 then return nil end
  local name = M.codex_title_name(title)
  local named = {}
  for _, r in ipairs(rows) do
    if name and r.name == name then named[#named + 1] = r.id end
  end
  if #named == 1 then return named[1] end
  if target then
    for _, r in ipairs(rows) do
      if (target.uuid and r.id == target.uuid) or (target.name and r.name == target.name) then
        if not shared then
          -- Unless a newer thread was written since, the named one is it.
          if rows[1].id == r.id or not rows[1].fresh then return r.id end
        end
      end
    end
  end
  if not shared then return rows[1].id end
  return nil, "another Codex runs in the same folder and its title doesn't name one thread"
end

-- Of Codex's session_index.jsonl text, the newest ID with this thread name.
function M.codex_id_by_name(index_text, name, decode)
  if not index_text or not name then return nil end
  local found
  for line in index_text:gmatch("[^\n]+") do
    local ok, e = pcall(decode, line)
    if ok and type(e) == "table" and e.thread_name == name and M.is_uuid(e.id) then found = e.id end
  end
  return found
end

-- The last line of a pane's screen, used to see whether its prompt is drawn
-- and nothing is being typed.
function M.cursor_line(content)
  if type(content) ~= "string" then return nil end
  content = content:gsub("[\r\n%s]+$", "")
  return content:match("([^\n]*)$")
end

-- state.json --------------------------------------------------------------
--
--   { version, instance_id, swept_at,
--     panes = { [block_id] = { agent, id, cwd, session, seen_at, missed } } }

function M.new_state(instance)
  return { version = M.STATE_VERSION, instance_id = instance, panes = {} }
end

function M.clean_state(raw)
  if type(raw) ~= "table" or raw.version ~= M.STATE_VERSION or type(raw.panes) ~= "table" then
    return M.new_state(nil)
  end
  local panes = {}
  for block_id, e in pairs(raw.panes) do
    if type(block_id) == "string" and type(e) == "table" and M.resume_line(e) then panes[block_id] = e end
  end
  raw.panes = panes
  return raw
end

-- Records what a sweep saw in one pane. Returns true when it changed.
function M.observe(state, block_id, seen, now)
  local old = state.panes[block_id]
  local changed = not old or old.agent ~= seen.agent or old.id ~= seen.id
  state.panes[block_id] = { agent = seen.agent, id = seen.id, cwd = seen.cwd,
                            session = seen.session, seen_at = now, missed = 0 }
  return changed
end

-- A pane where a sweep saw no agent. Only a timed sweep forgets, and only after
-- M.MISSES in a row: quitting Rex closes the agents seconds before the server
-- stops, and the sweeps that triggers must not lose them. A closed pane
-- (`gone`) is forgotten at the first timed sweep. Returns true if forgotten.
function M.miss(state, block_id, gone, timed)
  local e = state.panes[block_id]
  if not e or not timed then return false end
  e.missed = (e.missed or 0) + 1
  if gone or e.missed >= M.MISSES then
    state.panes[block_id] = nil
    return true
  end
  return false
end

-- The panes to type into after a restart, sorted by block ID, with one pane
-- per conversation. `previous` is the state the last server left.
function M.plan_restore(previous)
  local ids, plan, seen = {}, {}, {}
  for block_id in pairs(previous.panes or {}) do ids[#ids + 1] = block_id end
  table.sort(ids)
  for _, block_id in ipairs(ids) do
    local e = previous.panes[block_id]
    local key = e.agent .. " " .. e.id
    if not seen[key] then
      seen[key] = true
      plan[#plan + 1] = { block_id = block_id, entry = e }
    end
  end
  return plan
end

return M

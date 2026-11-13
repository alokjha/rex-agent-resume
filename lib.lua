-- lib.lua: the parts of rex-agent-resume that don't talk to Rex, so they can be
-- tested with a plain Lua interpreter. Written for Lua 5.1, which Rex embeds.

local M = {}

M.RESTORE_WINDOW_SECONDS = 120 -- after a server starts, how long panes may be typed into
M.SWEEP_INTERVAL_SECONDS = 15  -- between timed sweeps of every pane
M.MISSES_BEFORE_FORGETTING = 2 -- timed sweeps in a row an agent must be missing from
M.TYPEABLE_SHELLS = { zsh = true, bash = true, fish = true }
M.STATE_VERSION = 1

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

function M.is_uuid(value)
  return type(value) == "string" and value:find(UUID_PATTERN) ~= nil
end

-- Single-quoted for zsh, bash and fish alike. A backslash inside single quotes
-- means something different to fish, so text holding one is refused.
function M.shell_quote(text)
  text = tostring(text)
  if text:find("\\", 1, true) then return nil end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- The command that resumes an entry's conversation in its folder, or nil and why.
function M.resume_command(entry)
  if type(entry) ~= "table" or not M.is_uuid(entry.id) then return nil, "its session id isn't a UUID" end
  local command
  if entry.agent == "claude" then command = "claude --resume " .. entry.id
  elseif entry.agent == "codex" then command = "codex resume " .. entry.id
  else return nil, "unknown agent " .. tostring(entry.agent) end
  if entry.cwd then
    local quoted_folder = M.shell_quote(entry.cwd)
    if not quoted_folder then return nil, "its folder has a backslash" end
    command = "cd " .. quoted_folder .. " && " .. command
  end
  return command
end

-- What is typed into a pane to run `command`: Ctrl-U first, which clears
-- anything left on the line in zsh, bash and fish (in emacs and vi insert keys
-- alike), then the command and Enter.
function M.keystrokes_for(command)
  return "\21" .. command .. "\r"
end

-- `ps -o etime=` ("[[dd-]hh:]mm:ss") in seconds.
function M.parse_elapsed_time(text)
  if type(text) ~= "string" then return nil end
  text = text:match("^%s*(.-)%s*$")
  local days, clock = text:match("^(%d+)%-(.+)$")
  clock = clock or text
  local fields = {}
  for field in clock:gmatch("[^:]+") do
    if not field:find("^%d+$") then return nil end
    fields[#fields + 1] = tonumber(field)
  end
  if #fields < 2 or #fields > 3 or (days and #fields ~= 3) then return nil end
  local hours = #fields == 3 and fields[1] or 0
  return (tonumber(days) or 0) * 86400 + hours * 3600 + fields[#fields - 1] * 60 + fields[#fields]
end

-- An ISO-8601 UTC time ("2026-11-13T15:58:36.49Z") in Unix seconds.
function M.iso_to_unix_time(text)
  if type(text) ~= "string" then return nil end
  local year, month, day, hour, minute, second =
    text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then return nil end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  -- Days since 1970-01-01 (Howard Hinnant's days_from_civil).
  if month <= 2 then year = year - 1 end
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local shifted_month = (month + 9) % 12
  local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  local days = era * 146097 + day_of_era - 719468
  return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- Whether a pane is at its shell: its foreground process is the program Rex
-- started (the terminal's child, often `login`) or that program's child.
-- `process` is the terminal's `process` reply.
function M.is_at_shell(process)
  if type(process) ~= "table" then return false end
  local foreground, child = process.foreground, process.child
  if type(foreground) ~= "table" or type(child) ~= "table" or not foreground.pid then return false end
  if foreground.pid == child.pid then return true end
  local parent = type(process.ancestors) == "table" and process.ancestors[1]
  return type(parent) == "table" and parent.pid == child.pid
end

-- A process's program name, without its folder or a login shell's leading "-".
function M.program_name(process_info)
  if type(process_info) ~= "table" then return nil end
  local name = (process_info.argv0 or process_info.name or ""):match("([^/]+)$") or ""
  return (name:gsub("^%-", ""))
end

-- From `ps -ww -o etime=,args=`: the process's age in seconds and its
-- arguments as words. ps joins arguments with spaces, so an argument holding
-- one comes back split.
function M.parse_ps_line(line)
  if type(line) ~= "string" then return nil end
  local elapsed, command_line = line:match("^%s*(%S+)%s+(.-)%s*$")
  local age_seconds = M.parse_elapsed_time(elapsed)
  if not age_seconds then return nil end
  local argv = {}
  for word in command_line:gmatch("%S+") do argv[#argv + 1] = word end
  return age_seconds, argv
end

-- The conversation a codex command line names: `codex [options] resume X`.
-- Returns { uuid = X } or { name = X }, or nil.
function M.codex_resume_target(argv)
  if type(argv) ~= "table" then return nil end
  for i = 2, #argv do
    if argv[i] == "resume" then
      local target = argv[i + 1]
      if not target or target:sub(1, 1) == "-" then return nil end
      if M.is_uuid(target) then return { uuid = target } end
      return { name = table.concat(argv, " ", i + 1) }
    elseif argv[i]:sub(1, 1) ~= "-" and argv[i - 1]:sub(1, 1) ~= "-" then
      return nil -- another subcommand, or a prompt (a word after an option is its value)
    end
  end
  return nil
end

-- The thread name Codex shows in its title, "NAME | FOLDER", or the whole title.
function M.codex_thread_name_from_title(title)
  if type(title) ~= "string" or title == "" then return nil end
  return title:match("^(.-) | [^|]*$") or title
end

-- Chooses a Codex TUI's thread from `threads`: Codex's threads in its folder
-- that were written since it started (`written_since_start`) or that its
-- command line names (`resume_target`), newest first. `folder_is_shared` says
-- another Codex runs in the same folder. Returns the thread ID, or nil and why.
function M.choose_codex_thread(threads, title, resume_target, folder_is_shared)
  if type(threads) ~= "table" or #threads == 0 then return nil end
  local title_name = M.codex_thread_name_from_title(title)
  local named_in_title = {}
  for _, thread in ipairs(threads) do
    if title_name and thread.name == title_name then named_in_title[#named_in_title + 1] = thread.id end
  end
  if #named_in_title == 1 then return named_in_title[1] end
  if resume_target and not folder_is_shared then
    local newest = threads[1]
    for _, thread in ipairs(threads) do
      local is_target = (resume_target.uuid and thread.id == resume_target.uuid)
        or (resume_target.name and thread.name == resume_target.name)
      -- Unless a newer thread was written since, the one it resumed is it.
      if is_target and (newest.id == thread.id or not newest.written_since_start) then return thread.id end
    end
  end
  if not folder_is_shared then return threads[1].id end
  return nil, "another Codex runs in the same folder and its title doesn't name one thread"
end

-- Of Codex's session_index.jsonl text, the newest ID with this thread name.
function M.codex_id_from_index(index_text, thread_name, decode_json)
  if not index_text or not thread_name then return nil end
  local found
  for line in index_text:gmatch("[^\n]+") do
    local ok, indexed = pcall(decode_json, line)
    if ok and type(indexed) == "table" and indexed.thread_name == thread_name and M.is_uuid(indexed.id) then
      found = indexed.id
    end
  end
  return found
end

-- The last non-blank line of a pane's screen: its prompt line, once the prompt
-- is drawn. Watching it stay the same shows nothing is being typed.
function M.last_screen_line(screen_text)
  if type(screen_text) ~= "string" then return nil end
  screen_text = screen_text:gsub("[\r\n%s]+$", "")
  return screen_text:match("([^\n]*)$")
end

-- state.json --------------------------------------------------------------
--
--   { version, instance_id, swept_at,
--     panes = { [block_id] = { agent, id, cwd, session, seen_at, missed } } }

function M.new_state(instance_id)
  return { version = M.STATE_VERSION, instance_id = instance_id, panes = {} }
end

-- A state read from disk, with anything malformed dropped.
function M.sanitize_state(raw)
  if type(raw) ~= "table" or raw.version ~= M.STATE_VERSION or type(raw.panes) ~= "table" then
    return M.new_state(nil)
  end
  local panes = {}
  for block_id, entry in pairs(raw.panes) do
    if type(block_id) == "string" and type(entry) == "table" and M.resume_command(entry) then
      panes[block_id] = entry
    end
  end
  raw.panes = panes
  return raw
end

-- Records the agent a sweep found in a pane. Returns true when it's new or changed.
function M.record_agent(state, block_id, found, now)
  local old = state.panes[block_id]
  local changed = not old or old.agent ~= found.agent or old.id ~= found.id
  state.panes[block_id] = { agent = found.agent, id = found.id, cwd = found.cwd,
                            session = found.session, seen_at = now, missed = 0 }
  return changed
end

-- Notes that a sweep found no agent in a pane. Only a timed sweep forgets one,
-- and only after MISSES_BEFORE_FORGETTING in a row: quitting Rex closes the
-- agents seconds before the server stops, and the sweeps that triggers must not
-- lose them. A closed pane is forgotten at the first timed sweep. Returns true
-- when the pane's agent was forgotten.
function M.note_agent_missing(state, block_id, pane_closed, timed_sweep)
  local entry = state.panes[block_id]
  if not entry or not timed_sweep then return false end
  entry.missed = (entry.missed or 0) + 1
  if pane_closed or entry.missed >= M.MISSES_BEFORE_FORGETTING then
    state.panes[block_id] = nil
    return true
  end
  return false
end

-- Restoring one pane ----------------------------------------------------------
--
-- Each pane in a restore moves through these states, one step per look:
--
--   waiting ──prompt line read──▶ prompt_seen ──same line a second later──▶ typed
--      ▲                              │
--      └──────── anything else ───────┘
--
-- and from waiting or prompt_seen to the other final states:
--   already_running  the agent runs in the pane already
--   typed_elsewhere  another watcher typed it (restore.json says so)
--   failed           it can't be typed into; `why` says why

M.PANE_STATE = {
  WAITING = "waiting",
  PROMPT_SEEN = "prompt_seen",
  TYPED = "typed",
  ALREADY_RUNNING = "already_running",
  TYPED_ELSEWHERE = "typed_elsewhere",
  FAILED = "failed",
}
local S = M.PANE_STATE

function M.is_final_pane_state(state_name)
  return state_name == S.TYPED or state_name == S.ALREADY_RUNNING
    or state_name == S.TYPED_ELSEWHERE or state_name == S.FAILED
end

-- The next state of a pane in a restore, given what one look at it found.
-- `pane` is { state, prompt_line }. `look` is:
--   typed_elsewhere  restore.json marks the pane typed by another watcher
--   pane_exists      the pane is on the server
--   agent_running    its foreground program is the recorded agent
--   at_shell         its foreground is the shell Rex started
--   shell            that shell's name
--   editor_ready     the shell's line editor is reading keys
--   prompt_line      the last line of its screen
-- Returns the new { state, prompt_line, why }, and true when the resume
-- command is to be typed now.
function M.next_pane_state(pane, look)
  local function to(state_name, extra)
    local next_pane = { state = state_name }
    for k, v in pairs(extra or {}) do next_pane[k] = v end
    return next_pane
  end
  if M.is_final_pane_state(pane.state) then return pane, false end
  if look.typed_elsewhere then return to(S.TYPED_ELSEWHERE), false end
  if not look.pane_exists then return to(S.WAITING), false end
  if look.agent_running then return to(S.ALREADY_RUNNING), false end
  if not look.at_shell then return to(S.WAITING), false end
  if not M.TYPEABLE_SHELLS[look.shell] then
    return to(S.FAILED, { why = "its shell " .. tostring(look.shell) .. " isn't zsh, bash or fish" }), false
  end
  local line = look.editor_ready and look.prompt_line or nil
  if not line or line == "" then return to(S.WAITING), false end
  if pane.state == S.PROMPT_SEEN and pane.prompt_line == line then return to(S.TYPED), true end
  return to(S.PROMPT_SEEN, { prompt_line = line }), false
end

-- A restore as a whole (restore.json's `state`):
--
--   pending ──every pane final, or the window ends──▶ finished
--
-- A finished restore is never run again, even by a watcher started later in
-- the window (a config reload), so failures aren't retried or reported twice.
M.RESTORE_STATE = { PENDING = "pending", FINISHED = "finished" }

-- Whether a watcher on server `instance_id` should run `restore` at time `now`,
-- and if not, why. A restore.json from before `state` existed counts as pending.
function M.should_run_restore(restore, instance_id, now, deadline)
  if type(restore) ~= "table" then return false, "nothing to restore" end
  if restore.for_instance ~= instance_id then return false, "it is for another server" end
  if (restore.state or M.RESTORE_STATE.PENDING) ~= M.RESTORE_STATE.PENDING then return false, "it finished" end
  if now > deadline then return false, "the restore window has ended" end
  return true
end

-- What a sweep found in a pane:
--   agent               an agent whose conversation is known: recorded
--   agent_unidentified  an agent whose conversation can't be told now: the
--                       earlier record is kept
--   no_agent            something else runs: counts toward forgetting
--   unreadable          the pane's process couldn't be read: nothing changes
M.FINDING = {
  AGENT = "agent",
  AGENT_UNIDENTIFIED = "agent_unidentified",
  NO_AGENT = "no_agent",
  UNREADABLE = "unreadable",
}

M.AGENTS = { claude = true, codex = true }

function M.classify_finding(process_readable, program, identified)
  if not process_readable then return M.FINDING.UNREADABLE end
  if not M.AGENTS[program] then return M.FINDING.NO_AGENT end
  if identified then return M.FINDING.AGENT end
  return M.FINDING.AGENT_UNIDENTIFIED
end

-- The panes to type into after a restart, sorted by block ID, with one pane per
-- conversation: { { block_id, entry }, ... }. `previous_state` is what the last
-- server left.
function M.plan_restore(previous_state)
  local block_ids, plan, planned = {}, {}, {}
  for block_id in pairs(previous_state.panes or {}) do block_ids[#block_ids + 1] = block_id end
  table.sort(block_ids)
  for _, block_id in ipairs(block_ids) do
    local entry = previous_state.panes[block_id]
    local conversation = entry.agent .. " " .. entry.id
    if not planned[conversation] then
      planned[conversation] = true
      plan[#plan + 1] = { block_id = block_id, entry = entry }
    end
  end
  return plan
end

return M

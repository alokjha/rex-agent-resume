-- watcher.lua: records which Claude Code or Codex conversation runs in which Rex
-- pane, and types each one back into its pane after the Rex server restarts.
--
--   rex do --all watcher.lua                the watcher (rex-agent-resume.lua starts it)
--   rex do --all watcher.lua mode=resume    resume the last server's agents now, in
--                                           panes that are back at a shell prompt
--   rex do --all watcher.lua mode=status    print what is recorded
--
-- Options: state=DIR (default $XDG_STATE_HOME/rex-agent-resume), notify=0 to turn
-- off macOS notifications about agents that couldn't be resumed.

local args = rex.args or {}
local here = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."
local lib = dofile(here .. "/lib.lua")

local T = "com.superlogical.terminal"
local HOME = assert(os.getenv("HOME"), "HOME isn't set")
local STATE = args.state or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-agent-resume")
local STATE_FILE = STATE .. "/state.json"     -- this server's panes
local RESTORE_FILE = STATE .. "/restore.json" -- the last server's panes, and which were typed
local PIDFILE = STATE .. "/watcher.pid"
local CLAUDE_DIR = os.getenv("CLAUDE_CONFIG_DIR") or (HOME .. "/.claude")
local CODEX_DIR = os.getenv("CODEX_HOME") or (HOME .. "/.codex")
local NOTIFY = tostring(args.notify) ~= "0"
local mode = args.mode or "watch"
local me -- this watcher's pid, once known

-- Files ------------------------------------------------------------------

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function read_json(path)
  local text = read(path)
  if not text then return nil end
  local ok, v = pcall(rex.json.decode, text)
  return ok and v or nil
end

-- Written whole, to a file only you can read, then renamed over the old one.
local function write_json(path, value)
  -- Each watcher has its own temporary file, as several may run for a moment.
  local tmp = path .. ".tmp." .. tostring(me or os.time())
  local f = io.open(tmp, "w")
  if not f then return rex.log("warn", "can't write " .. tmp) end
  f:write(rex.json.encode(value, { indent = true }))
  f:close()
  rex.exec({ "chmod", "600", tmp })
  local ok, err = os.rename(tmp, path)
  if not ok then rex.log("warn", "can't save " .. path .. ": " .. tostring(err)) end
end

local function log(msg) rex.log("info", msg) end

-- Rex ---------------------------------------------------------------------

local function call(method, params)
  local r, err = rex.call(method, params or {})
  if r == nil and err then rex.log("warn", method .. ": " .. tostring(err)) end
  return r
end

local function block_call(b, method, params)
  params = params or {}
  params.session_id, params.block_id = b.session_id, b.block_id
  return rex.block.call(T, method, params)
end

local function server()
  local s = call("server.status")
  if not s or type(s.instance_id) ~= "string" then return nil end
  return { instance_id = s.instance_id, started_at = lib.iso_to_epoch(s.started_at) or os.time() }
end

-- Every terminal pane on the server as { block_id, session_id, session }, and
-- whether every session could be read.
local function collect(node, out, s)
  if type(node) ~= "table" then return end
  if type(node.block_id) == "string" and node.creator_name == T then
    out[#out + 1] = { block_id = node.block_id, session_id = s.session_id, session = s.label }
    return
  end
  for _, v in pairs(node) do
    if type(v) == "table" then collect(v, out, s) end
  end
end

local function terminals()
  local list = call("session.list")
  if not list then return {}, false end
  local out, complete = {}, true
  for _, s in ipairs(list.sessions or {}) do
    local view = rex.call("session.view", { session_id = s.session_id })
    if not view then
      local a = rex.call("session.attach", { session_id = s.session_id })
      view = a and (a.view or rex.call("session.view", { session_id = s.session_id }))
    end
    if view then collect(view.windows or view, out, s) else complete = false end
  end
  return out, complete
end

-- Which conversation runs in a pane ----------------------------------------

local verified = {} -- Claude session IDs whose transcript was found

local function claude_session(fg)
  local rec = read_json(CLAUDE_DIR .. "/sessions/" .. fg.pid .. ".json")
  if type(rec) ~= "table" or not lib.is_uuid(rec.sessionId) then return nil end
  if rec.pid and rec.pid ~= fg.pid then return nil end
  -- A session gets a transcript with its first message; before that there is
  -- nothing to resume.
  if not verified[rec.sessionId] then
    local r = rex.exec({ "/bin/sh", "-c",
      'for f in "$1"/projects/*/"$2".jsonl; do [ -e "$f" ] && exit 0; done; exit 1',
      "sh", CLAUDE_DIR, rec.sessionId })
    if not (r and r.ok) then return nil end
    verified[rec.sessionId] = true
  end
  return { agent = "claude", id = rec.sessionId, cwd = rec.cwd or fg.cwd }
end

local function sql(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

local codex_db_warned = false

-- Codex's newest state database, ~/.codex/state_N.sqlite. Its format belongs
-- to Codex and can change, so every use of it has a fallback.
local function codex_db()
  local r = rex.exec({ "/bin/sh", "-c", 'ls "$1"/state_*.sqlite 2>/dev/null', "sh", CODEX_DIR })
  local best, best_n
  for path in ((r and r.stdout) or ""):gmatch("[^\n]+") do
    local n = tonumber(path:match("state_(%d+)%.sqlite$"))
    if n and (not best_n or n > best_n) then best, best_n = path, n end
  end
  return best
end

-- Codex's threads in a folder written since `started_ms`, or named by `target`.
local function codex_rows(cwd, started_ms, target)
  local db = codex_db()
  if not db then return nil end
  local extra = ""
  if target and target.uuid then extra = " OR id = " .. sql(target.uuid) end
  if target and target.name then extra = " OR name = " .. sql(target.name) end
  local updated = "COALESCE(updated_at_ms, updated_at * 1000)"
  local q = "SELECT id, COALESCE(name, '') AS name, " .. updated .. " AS updated FROM threads"
    .. " WHERE archived = 0 AND cwd = " .. sql(cwd)
    -- Codex's own review threads and the desktop app's aren't a terminal's.
    .. " AND COALESCE(thread_source, 'user') = 'user'"
    .. " AND COALESCE(originator, '') <> 'codex_work_desktop'"
    .. " AND (" .. updated .. " >= " .. string.format("%d", started_ms) .. extra .. ")"
    .. " ORDER BY updated DESC LIMIT 20"
  local r = rex.exec({ "sqlite3", "-readonly", "-json", db, q }, { timeout = 5 })
  -- Codex's database is in WAL mode. A read-only reader can't create its -shm
  -- file, so it fails while no Codex has the database open. Then there is no
  -- -wal file either, and reading it as immutable sees everything.
  if not (r and r.ok) and not read(db .. "-wal") then
    local uri = "file:" .. db:gsub("[%%?# ]", function(c) return string.format("%%%02X", c:byte()) end)
      .. "?immutable=1"
    r = rex.exec({ "sqlite3", "-json", uri, q }, { timeout = 5 })
  end
  if not (r and r.ok) then
    if not codex_db_warned then
      codex_db_warned = true
      rex.log("warn", "can't read Codex's threads from " .. db .. ", using fallbacks: "
        .. tostring(r and r.stderr))
    end
    return nil
  end
  if not r.stdout:find("%S") then return {} end
  local ok, rows = pcall(rex.json.decode, r.stdout)
  if not ok or type(rows) ~= "table" then return nil end
  for _, row in ipairs(rows) do row.fresh = (tonumber(row.updated) or 0) >= started_ms end
  return rows
end

local function codex_session(b, fg, shared)
  local r = rex.exec({ "ps", "-ww", "-o", "etime=,args=", "-p", tostring(fg.pid) }, { timeout = 5 })
  local age, words = lib.parse_ps(r and r.ok and r.stdout)
  if not age then return nil end
  local target = lib.codex_target(words)
  local t = block_call(b, "title")
  local title = t and t.title
  local started_ms = (os.time() - age - 2) * 1000
  local rows = codex_rows(fg.cwd, started_ms, target)
  local id, why
  if rows then id, why = lib.pick_codex_thread(rows, title, target, shared) end
  if not id and target and target.uuid then id = target.uuid end
  if not id then
    local index = read(CODEX_DIR .. "/session_index.jsonl")
    id = lib.codex_id_by_name(index, lib.codex_title_name(title), rex.json.decode)
      or (target and lib.codex_id_by_name(index, target.name, rex.json.decode))
  end
  if not id then return nil, why end
  return { agent = "codex", id = id, cwd = fg.cwd }
end

-- State -----------------------------------------------------------------------

local srv     -- { instance_id, started_at } of the server this watcher talks to
local state   -- this server's panes (see lib.lua)
local stopped = false

local function save_state() write_json(STATE_FILE, state) end

-- Looks at every pane and records its agent. A timed sweep also forgets agents
-- that are gone (see lib.miss).
local function sweep(timed)
  if stopped or not srv then return end
  local blocks, complete = terminals()
  -- A failed or empty read never replaces what is recorded.
  if not complete or #blocks == 0 then return end
  local now = os.time()
  local procs, codex_in = {}, {}
  for _, b in ipairs(blocks) do
    local p = block_call(b, "process")
    procs[b.block_id] = p
    local fg = type(p) == "table" and p.foreground
    if fg and lib.program(fg) == "codex" and fg.cwd then codex_in[fg.cwd] = (codex_in[fg.cwd] or 0) + 1 end
  end
  local live = {}
  for _, b in ipairs(blocks) do
    live[b.block_id] = true
    local p = procs[b.block_id]
    local fg = type(p) == "table" and p.foreground
    local name = fg and fg.pid and lib.program(fg)
    local seen, why
    if name == "claude" then seen = claude_session(fg)
    elseif name == "codex" then seen, why = codex_session(b, fg, (codex_in[fg.cwd] or 0) > 1) end
    if seen then
      seen.session = b.session
      if lib.observe(state, b.block_id, seen, now) then
        log("recorded " .. seen.agent .. " " .. seen.id .. " in " .. tostring(b.session))
      end
    elseif name == "claude" or name == "codex" then
      -- The agent runs but its conversation can't be told now: keep what was recorded.
      if why then rex.log("warn", name .. " in " .. tostring(b.session) .. ": " .. why) end
    elseif p ~= nil then
      if lib.miss(state, b.block_id, false, timed) then log("forgot the agent in " .. tostring(b.session) .. ": it stopped") end
    end
  end
  for block_id in pairs(state.panes) do
    if not live[block_id] and lib.miss(state, block_id, true, timed) then
      log("forgot the agent in " .. block_id .. ": its pane closed")
    end
  end
  if timed then state.swept_at = now end
  save_state()
end

-- Restoring -------------------------------------------------------------------

local function applescript(s) return '"' .. s:gsub('[\\"]', "\\%0"):gsub("%s+", " ") .. '"' end

local function notify(text)
  rex.log("warn", text)
  if not NOTIFY then return end
  rex.exec({ "/usr/bin/osascript", "-e",
    "display notification " .. applescript(text) .. ' with title "rex-agent-resume"' })
end

-- Types each planned conversation into its pane once the pane sits at a fresh
-- shell prompt. `restore` is restore.json: { for_instance, panes, typed }.
-- `deadline` is when to give up; `on_done` runs at the end. `manual` is the
-- resume_agents action: it types into any recorded pane without its agent, and
-- leaves restore.json as it is.
local function run_restore(restore, deadline, on_done, manual)
  local pending, last, failed = {}, {}, {}
  for _, item in ipairs(lib.plan_restore(restore)) do
    if not restore.typed[item.block_id] then pending[item.block_id] = item.entry end
  end
  local function finish()
    for block_id, e in pairs(pending) do
      failed[#failed + 1] = e.agent .. " in " .. tostring(e.session) .. ": its pane wasn't at a shell prompt in time"
      pending[block_id] = nil
    end
    if #failed > 0 then
      notify("Couldn't resume " .. #failed .. " agent(s): " .. table.concat(failed, "; "))
    end
    if on_done then on_done() end
  end
  local function mark(block_id)
    restore.typed[block_id] = os.time()
    pending[block_id] = nil
    if not manual then write_json(RESTORE_FILE, restore) end
  end
  local function tick()
    if stopped then return end
    if next(pending) == nil or os.time() > deadline then return finish() end
    local live = {}
    for _, b in ipairs((terminals())) do live[b.block_id] = b end
    for block_id, e in pairs(pending) do
      local b = live[block_id]
      local p = b and block_call(b, "process")
      local fg = type(p) == "table" and p.foreground
      local line, why = lib.resume_line(e)
      if not line then
        failed[#failed + 1] = e.agent .. " in " .. tostring(e.session) .. ": " .. why
        pending[block_id] = nil
      elseif fg and lib.program(fg) == e.agent then
        log(e.agent .. " already runs in " .. tostring(e.session))
        mark(block_id)
      elseif fg and lib.at_shell(p) then
        if not lib.SHELLS[lib.program(fg)] then
          failed[#failed + 1] = e.agent .. " in " .. tostring(e.session) .. ": its shell "
            .. tostring(lib.program(fg)) .. " isn't zsh, bash or fish"
          pending[block_id] = nil
        else
          -- The line editor is reading keys, and the prompt line stayed the same
          -- for a second: the prompt is drawn and nothing is being typed.
          local im = block_call(b, "input_mode")
          local screen = im and im.canonical == false and block_call(b, "format", { trim = true })
          local cursor = screen and lib.cursor_line(screen.content)
          local disk = not manual and read_json(RESTORE_FILE)
          if type(disk) == "table" and type(disk.typed) == "table" and disk.typed[block_id] then
            pending[block_id] = nil -- another watcher typed it
          elseif cursor and cursor ~= "" and cursor == last[block_id] then
            mark(block_id) -- marked before typing, so a pane is never typed into twice
            block_call(b, "write", { data = lib.restore_input(line) })
            log("resumed " .. e.agent .. " " .. e.id .. " in " .. tostring(e.session))
          else
            last[block_id] = cursor
          end
        end
      else
        last[block_id] = nil
      end
    end
    rex.after(1, tick)
  end
  tick()
end

-- The watcher -----------------------------------------------------------------

local function my_pid()
  local r = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
  return r and r.ok and tonumber(r.stdout:match("%d+"))
end

local function is_watcher(pid)
  local r = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  return r and r.ok and r.stdout:find(here .. "/watcher.lua", 1, true) ~= nil
    and not r.stdout:find("mode=", 1, true)
end

local function stop(why)
  if stopped then return end
  stopped = true
  log("watcher stops: " .. why)
  rex.stop(0)
end

local function watch()
  rex.exec({ "mkdir", "-p", STATE })
  rex.exec({ "chmod", "700", STATE })
  -- One watcher at a time, the newest. An older one may be left from a server
  -- that has stopped, waiting on a connection that will never answer.
  me = my_pid()
  local other = tonumber(read(PIDFILE) or "")
  if other and other ~= me and is_watcher(other) then
    rex.exec({ "kill", tostring(other) })
    log("replaced the older watcher " .. other)
  end
  if me then
    local f = io.open(PIDFILE, "w")
    if f then f:write(tostring(me)) f:close() end
  end

  srv = server()
  if not srv then return stop("can't read the server's instance") end
  log("watcher " .. tostring(me) .. " started for server " .. srv.instance_id)

  local saved = lib.clean_state(read_json(STATE_FILE))
  if saved.instance_id and saved.instance_id ~= srv.instance_id then
    -- The first look at a new server: what the last one ran is to be restored,
    -- unless a watcher started at the same moment got there first.
    local existing = read_json(RESTORE_FILE)
    if not (type(existing) == "table" and existing.for_instance == srv.instance_id) then
      write_json(RESTORE_FILE, { for_instance = srv.instance_id, from_instance = saved.instance_id,
                                 panes = saved.panes, typed = {} })
    end
    state = lib.new_state(srv.instance_id)
    save_state()
  elseif saved.instance_id == srv.instance_id then
    state = saved
  else
    state = lib.new_state(srv.instance_id)
  end

  -- restore_test=1 counts the window from now, to test without a server restart.
  local deadline = (tostring(args.restore_test) == "1" and os.time() or srv.started_at) + lib.RESTORE_WINDOW
  -- Restoring waits until watchers started together have settled which one
  -- runs. A watcher replaced mid-restore leaves the rest to this one.
  rex.after(2, function()
    if stopped or tonumber(read(PIDFILE) or "") ~= me then return end
    local restore = read_json(RESTORE_FILE)
    if type(restore) == "table" and restore.for_instance == srv.instance_id and os.time() <= deadline then
      restore.typed = restore.typed or {}
      restore.panes = restore.panes or {}
      log("resuming the agents of server " .. tostring(restore.from_instance))
      run_restore(restore, deadline, function() log("restore finished") end)
    end
  end)

  sweep(false)
end

-- Rex takes handlers only while the script loads, so they are set up here and
-- do nothing until watch() has read the server.
if mode == "watch" then
  local pending
  local function sweep_soon()
    if pending or not srv then return end
    pending = true
    rex.after(2, function() pending = nil sweep(false) end)
  end
  rex.on("terminal.process_changed", sweep_soon)
  rex.on("block_closed", sweep_soon)
  rex.every(lib.SWEEP, function()
    if stopped or not srv then return end
    local now = server()
    -- A watcher that outlives its server leaves the new one to the watcher
    -- the new server starts.
    if now and now.instance_id ~= srv.instance_id then return stop("the server restarted") end
    sweep(true)
  end)
  -- Config loads can start several watchers at once. The one whose pid is in
  -- the file is the watcher; the others stop.
  rex.every(1, function()
    if stopped or not me then return end
    local owner = tonumber(read(PIDFILE) or "")
    if owner ~= me then stop("watcher " .. tostring(owner) .. " took over") end
  end)
end

local function resume_now()
  local restore = read_json(RESTORE_FILE)
  if type(restore) ~= "table" or type(restore.panes) ~= "table" then
    print("nothing to resume: no agents were recorded from an earlier server")
    return rex.stop(0)
  end
  -- Typed again only where the agent isn't running and the pane is at a prompt.
  restore.typed = {}
  run_restore(restore, os.time() + 10, function()
    print("done; see the log for what was resumed")
    rex.stop(0)
  end, true)
end

local function status()
  local s = lib.clean_state(read_json(STATE_FILE))
  print("server " .. tostring(s.instance_id) .. ", last timed sweep " ..
    (s.swept_at and os.date("%H:%M:%S", s.swept_at) or "never"))
  for _, e in pairs(s.panes) do
    print(string.format("  %-20s %-6s %s  %s", tostring(e.session), e.agent, e.id, e.cwd or ""))
  end
  local r = read_json(RESTORE_FILE)
  if type(r) == "table" and type(r.panes) == "table" then
    local n, t = 0, 0
    for b in pairs(r.panes) do n = n + 1 if r.typed and r.typed[b] then t = t + 1 end end
    print("last restore: " .. t .. " of " .. n .. " agent(s) typed, for server " .. tostring(r.for_instance))
  end
  rex.stop(0)
end

-- With --all, other sessions can be reached only once the top level has
-- finished, so the work starts from a timer.
rex.after(0, function()
  if mode == "watch" then watch()
  elseif mode == "resume" then resume_now()
  elseif mode == "status" then status()
  else
    print("unknown mode " .. tostring(mode) .. "; use watch, resume or status")
    rex.stop(2)
  end
end)

-- watcher.lua: records which agent conversation (Claude Code, Codex, or any
-- other agent in agents/) runs in which Rex pane, and types each one back into
-- its pane after the Rex server restarts.
--
--   rex do --all watcher.lua                the watcher (rex-agent-resume.lua starts it)
--   rex do --all watcher.lua mode=resume    resume the last server's agents now, in
--                                           panes that are back at a shell prompt
--   rex do --all watcher.lua mode=status    print what is recorded
--
-- Options:
--   state=DIR       where the records live (default $XDG_STATE_HOME/rex-agent-resume)
--   notify=0        no macOS notification about agents that couldn't be resumed
--   restore_test=1  count the 120-second restore window from now rather than from
--                   the server's start, to test a restore without restarting Rex

local args = rex.args or {}
local SCRIPT_DIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."
local lib = dofile(SCRIPT_DIR .. "/lib.lua")
local agents = dofile(SCRIPT_DIR .. "/agents/init.lua")(lib)

local TERMINAL = "com.superlogical.terminal" -- the Rex block type of a terminal pane
local HOME = assert(os.getenv("HOME"), "HOME isn't set")
local STATE_DIR = args.state or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-agent-resume")
local STATE_FILE = STATE_DIR .. "/state.json"     -- this server's panes
local RESTORE_FILE = STATE_DIR .. "/restore.json" -- the last server's panes, and which were typed
local PID_FILE = STATE_DIR .. "/watcher.pid"
local NOTIFY_ON_FAILURE = tostring(args.notify) ~= "0"
local mode = args.mode or "watch"
local my_pid -- this watcher's pid, once known

-- Files ------------------------------------------------------------------

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function read_json(path)
  local text = read_file(path)
  if not text then return nil end
  local ok, value = pcall(rex.json.decode, text)
  return ok and value or nil
end

-- Written whole, to a file only you can read, then renamed over the old one.
local function write_json(path, value)
  -- Each watcher has its own temporary file, as several may run for a moment.
  local temp_path = path .. ".tmp." .. tostring(my_pid or os.time())
  local file = io.open(temp_path, "w")
  if not file then return rex.log("warn", "can't write " .. temp_path) end
  file:write(rex.json.encode(value, { indent = true }))
  file:close()
  rex.exec({ "chmod", "600", temp_path })
  local ok, err = os.rename(temp_path, path)
  if not ok then rex.log("warn", "can't save " .. path .. ": " .. tostring(err)) end
end

local function log(message) rex.log("info", message) end

-- Rex ---------------------------------------------------------------------

local function server_call(method, params)
  local result, err = rex.call(method, params or {})
  if result == nil and err then rex.log("warn", method .. ": " .. tostring(err)) end
  return result
end

-- Calls a method of a pane's terminal, such as "process", "title" or "write".
local function terminal_call(pane, method, params)
  params = params or {}
  params.session_id, params.block_id = pane.session_id, pane.block_id
  return rex.block.call(TERMINAL, method, params)
end

-- { instance_id, started_at } of the server, or nil.
local function read_server_info()
  local status = server_call("server.status")
  if not status or type(status.instance_id) ~= "string" then return nil end
  return { instance_id = status.instance_id,
           started_at = lib.iso_to_unix_time(status.started_at) or os.time() }
end

-- Adds every terminal pane under `node`, a session's view, to `panes`.
local function collect_terminal_panes(node, panes, session)
  if type(node) ~= "table" then return end
  if type(node.block_id) == "string" and node.creator_name == TERMINAL then
    panes[#panes + 1] = { block_id = node.block_id, session_id = session.session_id, session = session.label }
    return
  end
  for _, child in pairs(node) do
    if type(child) == "table" then collect_terminal_panes(child, panes, session) end
  end
end

-- Every terminal pane on the server as { block_id, session_id, session }, and
-- whether every session could be read.
local function list_terminal_panes()
  local list = server_call("session.list")
  if not list then return {}, false end
  local panes, complete = {}, true
  for _, session in ipairs(list.sessions or {}) do
    local view = rex.call("session.view", { session_id = session.session_id })
    if not view then
      local attached = rex.call("session.attach", { session_id = session.session_id })
      view = attached and (attached.view or rex.call("session.view", { session_id = session.session_id }))
    end
    if view then collect_terminal_panes(view.windows or view, panes, session) else complete = false end
  end
  return panes, complete
end

-- What an agent may use (see agents/init.lua) --------------------------------

local host = {
  home = HOME,
  getenv = os.getenv,
  now = os.time,
  read_file = read_file,
  read_json = read_json,
  decode_json = rex.json.decode,
  exec = rex.exec,
  warn = function(message) rex.log("warn", message) end,
  terminal_call = terminal_call,
}

-- The registered agent whose program is `foreground`, or nil.
local function agent_of(foreground)
  return foreground and agents.by_program[lib.program_name(foreground)]
end

-- State -----------------------------------------------------------------------

local server_info -- { instance_id, started_at } of the server this watcher talks to
local state       -- this server's panes (see lib.lua)
-- The script's phase:  starting ──read the server──▶ running ──▶ stopped
-- Handlers do nothing until it runs, and nothing after it stops.
local phase = "starting"

local function save_state() write_json(STATE_FILE, state) end

-- Looks at every pane and records its agent. A timed sweep also forgets agents
-- that are gone (see lib.note_agent_missing).
local function sweep_panes(timed)
  if phase ~= "running" then return end
  local panes, complete = list_terminal_panes()
  -- A failed or empty read never replaces what is recorded.
  if not complete or #panes == 0 then return end
  local now = os.time()
  -- Every pane's process, and the panes each agent runs in (its detect's `peers`).
  local process_by_pane, peers_by_agent = {}, {}
  for _, pane in ipairs(panes) do
    local process = terminal_call(pane, "process")
    process_by_pane[pane.block_id] = process
    local foreground = type(process) == "table" and process.foreground or nil
    local agent = foreground and foreground.pid and agent_of(foreground)
    if agent then
      peers_by_agent[agent.name] = peers_by_agent[agent.name] or {}
      table.insert(peers_by_agent[agent.name], { pane = pane, foreground = foreground })
    end
  end
  local live_panes = {}
  for _, pane in ipairs(panes) do
    live_panes[pane.block_id] = true
    local process = process_by_pane[pane.block_id]
    local foreground = type(process) == "table" and process.foreground or nil
    local agent = foreground and foreground.pid and agent_of(foreground) or nil
    local found, why
    if agent then
      local ok, detected, reason = pcall(agent.detect, pane, foreground, peers_by_agent[agent.name], host)
      if ok then found, why = detected, reason else why = "its detect failed: " .. tostring(detected) end
      if found then found.agent = agent.name end
    end
    local finding = lib.classify_finding(process ~= nil, agent, found ~= nil)
    if finding == lib.FINDING.AGENT then
      found.session = pane.session
      if lib.record_agent(state, pane.block_id, found, now) then
        log("recorded " .. found.agent .. " " .. found.id .. " in " .. tostring(pane.session))
      end
    elseif finding == lib.FINDING.AGENT_UNIDENTIFIED then
      if why then rex.log("warn", agent.name .. " in " .. tostring(pane.session) .. ": " .. why) end
    elseif finding == lib.FINDING.NO_AGENT then
      if lib.note_agent_missing(state, pane.block_id, false, timed) then
        log("forgot the agent in " .. tostring(pane.session) .. ": it stopped")
      end
    end -- UNREADABLE: nothing changes
  end
  for block_id in pairs(state.panes) do
    if not live_panes[block_id] and lib.note_agent_missing(state, block_id, true, timed) then
      log("forgot the agent in " .. block_id .. ": its pane closed")
    end
  end
  if timed then state.swept_at = now end
  save_state()
end

-- Resuming -------------------------------------------------------------------

local function applescript_string(text)
  return '"' .. text:gsub('[\\"]', "\\%0"):gsub("%s+", " ") .. '"'
end

local function notify(text)
  rex.log("warn", text)
  if not NOTIFY_ON_FAILURE then return end
  rex.exec({ "/usr/bin/osascript", "-e",
    "display notification " .. applescript_string(text) .. ' with title "rex-agent-resume"' })
end

-- Looks at a pane once, for lib.next_pane_state.
local function look_at_pane(pane, entry, typed_on_disk)
  local look = { typed_elsewhere = typed_on_disk, pane_exists = pane ~= nil }
  if not pane then return look end
  local process = terminal_call(pane, "process")
  local foreground = type(process) == "table" and process.foreground
  if not foreground then return look end
  local running = agent_of(foreground)
  look.agent_running = running ~= nil and running.name == entry.agent
  look.at_shell = lib.is_at_shell(process)
  look.shell = lib.program_name(foreground)
  if look.at_shell and lib.TYPEABLE_SHELLS[look.shell] then
    local input_mode = terminal_call(pane, "input_mode")
    look.editor_ready = input_mode and input_mode.canonical == false or false
    if look.editor_ready then
      local screen = terminal_call(pane, "format", { trim = true })
      look.prompt_line = screen and lib.last_screen_line(screen.content)
    end
  end
  return look
end

-- Types each planned conversation into its pane once the pane sits at a fresh
-- shell prompt, stepping every pane through lib.PANE_STATE once a second.
-- `restore` is restore.json: { for_instance, state, panes, typed, failed }.
-- `deadline` is when to give up; `on_done` runs at the end. `manual` is the
-- resume_agents action: it types into any recorded pane without its agent, and
-- leaves restore.json as it is.
local function resume_recorded_agents(restore, deadline, on_done, manual)
  local S = lib.PANE_STATE
  local panes = {} -- block_id -> { entry, state, prompt_line, why }
  for _, planned in ipairs(lib.plan_restore(restore)) do
    if not restore.typed[planned.block_id] then
      local command, why = lib.resume_command(planned.entry, agents)
      panes[planned.block_id] = { entry = planned.entry, command = command,
                                  state = command and S.WAITING or S.FAILED, why = why }
    end
  end

  local function describe(pane) return pane.entry.agent .. " in " .. tostring(pane.entry.session) end

  local function finish()
    local failures, counts = {}, {}
    restore.failed = {}
    for block_id, pane in pairs(panes) do
      if not lib.is_final_pane_state(pane.state) then
        pane.state, pane.why = S.FAILED, "its pane wasn't at a shell prompt in time"
      end
      counts[pane.state] = (counts[pane.state] or 0) + 1
      if pane.state == S.FAILED then
        failures[#failures + 1] = describe(pane) .. ": " .. pane.why
        restore.failed[block_id] = pane.why
      end
    end
    if manual then
      -- The action shows its output; a notification for each busy pane would be noise.
      print(string.format("resumed %d, already running %d, not resumed %d",
        counts[S.TYPED] or 0, counts[S.ALREADY_RUNNING] or 0, #failures))
      for _, failure in ipairs(failures) do print("  " .. failure) end
    else
      restore.state = lib.RESTORE_STATE.FINISHED
      write_json(RESTORE_FILE, restore)
      if #failures > 0 then
        notify("Couldn't resume " .. #failures .. " agent(s): " .. table.concat(failures, "; "))
      end
    end
    if on_done then on_done() end
  end

  local function step()
    if phase == "stopped" then return end
    local all_final = true
    for _, pane in pairs(panes) do
      if not lib.is_final_pane_state(pane.state) then all_final = false end
    end
    if all_final or os.time() > deadline then return finish() end

    local live_panes = {}
    for _, live in ipairs((list_terminal_panes())) do live_panes[live.block_id] = live end
    local on_disk = not manual and read_json(RESTORE_FILE)
    local typed_on_disk = type(on_disk) == "table" and type(on_disk.typed) == "table" and on_disk.typed or {}

    for block_id, pane in pairs(panes) do
      if not lib.is_final_pane_state(pane.state) then
        local live = live_panes[block_id]
        local look = look_at_pane(live, pane.entry, typed_on_disk[block_id] ~= nil)
        local next_pane, type_now = lib.next_pane_state(pane, look)
        pane.state, pane.prompt_line, pane.why = next_pane.state, next_pane.prompt_line, next_pane.why
        if type_now then
          -- Marked before typing, so a pane is never typed into twice.
          restore.typed[block_id] = os.time()
          if not manual then write_json(RESTORE_FILE, restore) end
          terminal_call(live, "write", { data = lib.keystrokes_for(pane.command) })
          log("resumed " .. pane.entry.agent .. " " .. pane.entry.id .. " in " .. tostring(pane.entry.session))
        elseif pane.state == S.ALREADY_RUNNING then
          restore.typed[block_id] = os.time()
          if not manual then write_json(RESTORE_FILE, restore) end
          log(describe(pane) .. " already runs")
        end
      end
    end
    rex.after(1, step)
  end
  step()
end

-- The watcher -----------------------------------------------------------------

-- The pid of the `rex do` process running this script.
local function find_own_pid()
  local result = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
  return result and result.ok and tonumber(result.stdout:match("%d+"))
end

local function is_running_watcher(pid)
  local result = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  return result and result.ok and result.stdout:find(SCRIPT_DIR .. "/watcher.lua", 1, true) ~= nil
    and not result.stdout:find("mode=", 1, true)
end

local function stop_watcher(why)
  if phase == "stopped" then return end
  phase = "stopped"
  log("watcher stops: " .. why)
  rex.stop(0)
end

local function run_watcher()
  rex.exec({ "mkdir", "-p", STATE_DIR })
  rex.exec({ "chmod", "700", STATE_DIR })
  -- One watcher at a time, the newest. An older one may be left from a server
  -- that has stopped, waiting on a connection that will never answer.
  my_pid = find_own_pid()
  local older_pid = tonumber(read_file(PID_FILE) or "")
  if older_pid and older_pid ~= my_pid and is_running_watcher(older_pid) then
    rex.exec({ "kill", tostring(older_pid) })
    log("replaced the older watcher " .. older_pid)
  end
  if my_pid then
    local file = io.open(PID_FILE, "w")
    if file then file:write(tostring(my_pid)) file:close() end
  end

  server_info = read_server_info()
  if not server_info then return stop_watcher("can't read the server's instance") end
  phase = "running"
  log("watcher " .. tostring(my_pid) .. " started for server " .. server_info.instance_id)

  local saved_state = lib.sanitize_state(read_json(STATE_FILE), agents)
  if saved_state.instance_id and saved_state.instance_id ~= server_info.instance_id then
    -- The first look at a new server: what the last one ran is to be restored,
    -- unless a watcher started at the same moment got there first.
    local existing_restore = read_json(RESTORE_FILE)
    if not (type(existing_restore) == "table" and existing_restore.for_instance == server_info.instance_id) then
      write_json(RESTORE_FILE, { for_instance = server_info.instance_id, from_instance = saved_state.instance_id,
                                 state = lib.RESTORE_STATE.PENDING, panes = saved_state.panes, typed = {} })
    end
    state = lib.new_state(server_info.instance_id)
    save_state()
  elseif saved_state.instance_id == server_info.instance_id then
    state = saved_state
  else
    state = lib.new_state(server_info.instance_id)
  end

  -- restore_test=1 counts the window from now, to test without a server restart.
  local window_start = tostring(args.restore_test) == "1" and os.time() or server_info.started_at
  local deadline = window_start + lib.RESTORE_WINDOW_SECONDS
  -- Resuming waits until watchers started together have settled which one
  -- runs. A watcher replaced mid-restore leaves the rest to this one.
  rex.after(2, function()
    if phase ~= "running" or tonumber(read_file(PID_FILE) or "") ~= my_pid then return end
    local restore = read_json(RESTORE_FILE)
    if lib.should_run_restore(restore, server_info.instance_id, os.time(), deadline) then
      restore.typed = restore.typed or {}
      restore.panes = restore.panes or {}
      log("resuming the agents of server " .. tostring(restore.from_instance))
      resume_recorded_agents(restore, deadline, function() log("restore finished") end)
    end
  end)

  sweep_panes(false)
end

-- Rex takes handlers only while the script loads, so they are set up here and
-- do nothing until run_watcher() has read the server.
if mode == "watch" then
  local sweep_scheduled = false
  local function sweep_soon()
    if sweep_scheduled or phase ~= "running" then return end
    sweep_scheduled = true
    rex.after(2, function() sweep_scheduled = false sweep_panes(false) end)
  end
  rex.on("terminal.process_changed", sweep_soon)
  rex.on("block_closed", sweep_soon)
  rex.every(lib.SWEEP_INTERVAL_SECONDS, function()
    if phase ~= "running" then return end
    local current = read_server_info()
    -- A watcher that outlives its server leaves the new one to the watcher
    -- the new server starts.
    if current and current.instance_id ~= server_info.instance_id then
      return stop_watcher("the server restarted")
    end
    sweep_panes(true)
  end)
  -- Config loads can start several watchers at once. The one whose pid is in
  -- the file is the watcher; the others stop.
  rex.every(1, function()
    if phase ~= "running" or not my_pid then return end
    local pid_file_owner = tonumber(read_file(PID_FILE) or "")
    if pid_file_owner ~= my_pid then stop_watcher("watcher " .. tostring(pid_file_owner) .. " took over") end
  end)
end

local function run_manual_resume()
  phase = "running"
  local restore = read_json(RESTORE_FILE)
  if type(restore) ~= "table" or type(restore.panes) ~= "table" then
    print("nothing to resume: no agents were recorded from an earlier server")
    return rex.stop(0)
  end
  -- Typed again only where the agent isn't running and the pane is at a prompt.
  restore.typed = {}
  resume_recorded_agents(restore, os.time() + 10, function() rex.stop(0) end, true)
end

local function print_status()
  local recorded = lib.sanitize_state(read_json(STATE_FILE), agents)
  print("server " .. tostring(recorded.instance_id) .. ", last timed sweep " ..
    (recorded.swept_at and os.date("%H:%M:%S", recorded.swept_at) or "never"))
  for _, entry in pairs(recorded.panes) do
    print(string.format("  %-20s %-6s %s  %s", tostring(entry.session), entry.agent, entry.id, entry.cwd or ""))
  end
  local restore = read_json(RESTORE_FILE)
  if type(restore) == "table" and type(restore.panes) == "table" then
    local planned, typed = 0, 0
    for block_id in pairs(restore.panes) do
      planned = planned + 1
      if restore.typed and restore.typed[block_id] then typed = typed + 1 end
    end
    print("last restore (" .. tostring(restore.state or "pending") .. "): " .. typed .. " of " .. planned
      .. " agent(s) typed, for server " .. tostring(restore.for_instance))
    for block_id, why in pairs(type(restore.failed) == "table" and restore.failed or {}) do
      local entry = restore.panes[block_id]
      print("  failed: " .. tostring(entry and entry.session) .. ": " .. tostring(why))
    end
  end
  rex.stop(0)
end

-- With --all, other sessions can be reached only once the top level has
-- finished, so the work starts from a timer.
rex.after(0, function()
  if mode == "watch" then run_watcher()
  elseif mode == "resume" then run_manual_resume()
  elseif mode == "status" then print_status()
  else
    print("unknown mode " .. tostring(mode) .. "; use watch, resume or status")
    rex.stop(2)
  end
end)

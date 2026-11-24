-- watcher.lua: records which agent conversation runs in which Rex pane, and
-- types each one back into its pane after the Rex server restarts. The work is
-- in core/; the agents are in agents/.
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
local SCRIPT = SCRIPT_DIR .. "/watcher.lua"
local core = dofile(SCRIPT_DIR .. "/core/init.lua")
local agents, skipped_agents = dofile(SCRIPT_DIR .. "/agents/init.lua")(core)
for _, problem in ipairs(skipped_agents) do rex.log("warn", "skipped " .. problem) end

local files, recording, restore = core.files, core.recording, core.restore
local HOME = assert(os.getenv("HOME"), "HOME isn't set")
local STATE_DIR = args.state or ((os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-agent-resume")
local mode = args.mode or "watch"

local function log(message) rex.log("info", message) end

-- The watcher: what the core modules share. Kept in one table, not in locals
-- the handlers capture, so every handler sees the same values.
local watcher = {
  agents = agents,
  host = core.host.new(HOME),
  paths = {
    state_file = STATE_DIR .. "/state.json",     -- this server's panes
    restore_file = STATE_DIR .. "/restore.json", -- the last server's panes, and which were typed
    pid_file = STATE_DIR .. "/watcher.pid",
  },
  notify_on_failure = tostring(args.notify) ~= "0",
  phase = core.PHASE.STARTING, -- see core/init.lua
  pid = nil,    -- this watcher's pid, once known
  server = nil, -- { instance_id, started_at } of the server this watcher talks to
  state = nil,  -- this server's panes (core/recording.lua)
}

local function stop_watcher(why)
  if watcher.phase == core.PHASE.STOPPED then return end
  watcher.phase = core.PHASE.STOPPED
  log("watcher stops: " .. why)
  rex.stop(0)
end

local function run_watcher()
  rex.exec({ "mkdir", "-p", STATE_DIR })
  rex.exec({ "chmod", "700", STATE_DIR })
  core.singleton.take_over(watcher, SCRIPT)
  watcher.server = core.rex_server.read_server_info()
  if not watcher.server then return stop_watcher("can't read the server's instance") end
  watcher.phase = core.PHASE.RUNNING
  log("watcher " .. tostring(watcher.pid) .. " started for server " .. watcher.server.instance_id)

  local saved = recording.sanitize_state(files.read_json(watcher.paths.state_file), agents)
  local to_restore, save_now
  watcher.state, to_restore, save_now = recording.start(saved, watcher.server.instance_id, files.read_json(watcher.paths.restore_file), os.time())
  if to_restore then files.write_json(watcher.paths.restore_file, to_restore, watcher.pid) end
  if save_now then files.write_json(watcher.paths.state_file, watcher.state, watcher.pid) end

  -- restore_test=1 counts the window from now, to test without a server restart.
  local window_start = tostring(args.restore_test) == "1" and os.time() or watcher.server.started_at
  local deadline = window_start + restore.WINDOW_SECONDS
  -- Resuming waits until watchers started together have settled which one
  -- runs. A watcher replaced mid-restore leaves the rest to this one.
  rex.after(2, function()
    if watcher.phase ~= core.PHASE.RUNNING or not core.singleton.is_the_watcher(watcher) then return end
    local last_restore = files.read_json(watcher.paths.restore_file)
    if restore.should_run(last_restore, watcher.server.instance_id, os.time(), deadline) then
      last_restore.typed = last_restore.typed or {}
      last_restore.panes = last_restore.panes or {}
      log("resuming the agents of server " .. tostring(last_restore.from_instance))
      core.resume.run(watcher, last_restore, { started = core.resume.STARTED.AFTER_RESTART, deadline = deadline,
                                         on_done = function() log("restore finished") end })
    end
  end)

  core.sweep.run(watcher, recording.SWEEP.ON_EVENT)
end

-- Rex takes handlers only while the script loads, so they are set up here and
-- do nothing until run_watcher() has read the server.
if mode == "watch" then
  local scheduled = { sweep = false }
  local function sweep_soon()
    if scheduled.sweep or watcher.phase ~= core.PHASE.RUNNING then return end
    scheduled.sweep = true
    rex.after(2, function()
      scheduled.sweep = false
      if watcher.phase == core.PHASE.RUNNING then core.sweep.run(watcher, recording.SWEEP.ON_EVENT) end
    end)
  end
  rex.on("terminal.process_changed", sweep_soon)
  rex.on("block_closed", sweep_soon)
  rex.every(recording.SWEEP_INTERVAL_SECONDS, function()
    if watcher.phase ~= core.PHASE.RUNNING then return end
    local current = core.rex_server.read_server_info()
    -- A watcher that outlives its server leaves the new one to the watcher
    -- the new server starts.
    if current and current.instance_id ~= watcher.server.instance_id then
      return stop_watcher("the server restarted")
    end
    core.sweep.run(watcher, recording.SWEEP.TIMED)
  end)
  rex.every(1, function()
    if watcher.phase ~= core.PHASE.RUNNING or not watcher.pid then return end
    if not core.singleton.is_the_watcher(watcher) then
      stop_watcher("watcher " .. tostring(core.singleton.pid_file_owner(watcher)) .. " took over")
    end
  end)
end

local function resume_by_hand()
  watcher.phase = core.PHASE.RUNNING
  local last_restore = files.read_json(watcher.paths.restore_file)
  if type(last_restore) ~= "table" or type(last_restore.panes) ~= "table" then
    print("nothing to resume: no agents were recorded from an earlier server")
    return rex.stop(0)
  end
  -- Typed again only where the agent isn't running and the pane is at a prompt.
  last_restore.typed = {}
  core.resume.run(watcher, last_restore, { started = core.resume.STARTED.BY_HAND, deadline = os.time() + 10,
                                     on_done = function() rex.stop(0) end })
end

-- With --all, other sessions can be reached only once the top level has
-- finished, so the work starts from a timer.
rex.after(0, function()
  if mode == "watch" then run_watcher()
  elseif mode == "resume" then resume_by_hand()
  elseif mode == "status" then core.status.print(watcher) rex.stop(0)
  else
    print("unknown mode " .. tostring(mode) .. "; use watch, resume or status")
    rex.stop(2)
  end
end)

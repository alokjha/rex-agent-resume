-- core/init.lua: loads the core, which knows no agent by name. Each module gets
-- the modules it needs as its arguments. Modules that use `rex` do so only when
-- called, so the core loads in plain Lua for the tests.

local dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."

local function load(name, ...)
  return assert(loadfile(dir .. "/" .. name .. ".lua"))(...)
end

local core = {}

-- The watcher's phase:  starting ──read the server──▶ running ──▶ stopped
-- Handlers do nothing until it runs, and nothing after it stops.
core.PHASE = { STARTING = "starting", RUNNING = "running", STOPPED = "stopped" }

-- The rules, which don't talk to Rex.
core.agent_protocol = load("agent_protocol")     -- the Agent and Host protocols, and the registry
core.shell = load("shell")                       -- small helpers about shells and processes
core.restore = load("restore", core.shell)       -- when and what is typed back into a pane
core.recording = load("recording", core.restore) -- state.json: recording and forgetting
-- What talks to Rex.
core.files = load("files")                       -- reading and writing the watcher's files
core.rex_server = load("rex_server")             -- asking the Rex server about itself and its panes
core.host = load("host", core.agent_protocol, core.files, core.rex_server) -- what agents may use
core.singleton = load("singleton", core.files)   -- one watcher at a time
core.sweep = load("sweep", core.shell, core.recording, core.rex_server, core.files)
core.resume = load("resume", core.shell, core.restore, core.rex_server, core.files, core.PHASE)
core.status = load("status", core.recording, core.restore, core.files)
return core

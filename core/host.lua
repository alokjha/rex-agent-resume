-- core/host.lua: the host the watcher lends every agent, implementing the Host
-- protocol (core/agent_protocol.lua). Agents use only this, never `rex`.

local agent_protocol, files, rex_server = ...

local M = {}

function M.new(home)
  local host = {
    home = home,
    getenv = os.getenv,
    now = os.time,
    read_file = files.read_file,
    read_json = files.read_json,
    decode_json = function(text) return rex.json.decode(text) end,
    -- rex.exec is a callable table, not a function; the protocol wants a function.
    exec = function(argv, options) return rex.exec(argv, options) end,
    warn = function(message) rex.log("warn", message) end,
    terminal_call = rex_server.terminal_call,
  }
  local problem = agent_protocol.problem(agent_protocol.HOST, host)
  assert(not problem, problem)
  return host
end

return M

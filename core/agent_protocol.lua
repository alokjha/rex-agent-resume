-- core/agent_protocol.lua: what an agent must provide, what the watcher lends
-- it, and the registry of agents. Written for Lua 5.1, which Rex embeds.

local M = {}

-- The Agent protocol: every agent, agents/<name>/<name>.lua, is a table with
-- exactly these.
M.AGENT = {
  name = "string",             -- recorded in state.json: letters, digits, _ or -
  programs = "table",          -- the foreground program names that mean it runs
  is_valid_id = "function",    -- (id) -> boolean. The ID is typed into a shell: accept only safe ones.
  resume_command = "function", -- (id) -> the command that resumes conversation id
  detect = "function",         -- (pane, foreground, peers, host) -> { id, cwd }, or nil and why
}

-- The Host protocol: what the watcher lends an agent, which uses only this,
-- never `rex`, so tests can pass a fake host.
M.HOST = {
  home = "string",             -- the home folder
  getenv = "function",         -- (name) -> value or nil
  now = "function",            -- () -> Unix seconds
  read_file = "function",      -- (path) -> text or nil
  read_json = "function",      -- (path) -> decoded value or nil
  decode_json = "function",    -- (text) -> value; errors on bad JSON
  exec = "function",           -- (argv, options) -> { ok, stdout, stderr }, as rex.exec
  warn = "function",           -- (message) logs a warning
  terminal_call = "function",  -- (pane, method, params) -> the pane's terminal's reply
}

-- Why `value` doesn't conform to `protocol`, or nil when it does: every
-- member there and of its type, and nothing else.
function M.problem(protocol, value)
  if type(value) ~= "table" then return "it isn't a table" end
  for member, wanted in pairs(protocol) do
    if type(value[member]) ~= wanted then return member .. " must be a " .. wanted end
  end
  for member in pairs(value) do
    if not protocol[member] then return tostring(member) .. " isn't part of the protocol" end
  end
  return nil
end

-- The registry of agents: { list, by_name, by_program }, and why any agent
-- was left out. One that doesn't conform, or clashes with one already in, is
-- left out rather than fatal, so it doesn't stop the others.
function M.new_registry(agents)
  local registry, skipped = { list = {}, by_name = {}, by_program = {} }, {}
  for i, agent in ipairs(agents) do
    local label = "agent " .. (type(agent) == "table" and tostring(agent.name) or i)
    local problem = M.problem(M.AGENT, agent)
    if not problem and not agent.name:find("^[%w_%-]+$") then problem = "its name must be letters, digits, _ or -" end
    if not problem and #agent.programs == 0 then problem = "it has no programs" end
    if not problem and registry.by_name[agent.name] then problem = "it is there twice" end
    if not problem then
      for _, program in ipairs(agent.programs) do
        local other = registry.by_program[program]
        if other then problem = "agent " .. other.name .. " already claims " .. tostring(program) break end
      end
    end
    if problem then
      skipped[#skipped + 1] = label .. ": " .. problem
    else
      for _, program in ipairs(agent.programs) do registry.by_program[program] = agent end
      registry.by_name[agent.name] = agent
      registry.list[#registry.list + 1] = agent
    end
  end
  return registry, skipped
end

return M

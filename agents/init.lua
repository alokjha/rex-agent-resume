-- agents/init.lua: the agents rex-agent-resume can resume, one folder each.
-- To add one, write agents/<name>/<name>.lua and add <name> to AGENTS.
--
-- That file implements the Agent protocol (core/agent_protocol.lua). It is
-- loaded with core/shell.lua and its own folder as arguments
-- (`local shell, folder = ...`), so it can load helper files from its folder.
-- Those helpers are the agent's own: nothing else uses them.

local AGENTS = { "claude", "codex" }

local dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."

-- The registry of the agents that load and implement the protocol, and why
-- any were skipped. A broken agent is skipped, not fatal: the others still work.
return function(core)
  local list, skipped = {}, {}
  for _, name in ipairs(AGENTS) do
    local folder = dir .. "/" .. name
    local chunk, load_error = loadfile(folder .. "/" .. name .. ".lua")
    local ok, agent = false, load_error
    if chunk then ok, agent = pcall(chunk, core.shell, folder) end
    if ok then list[#list + 1] = agent
    else skipped[#skipped + 1] = "agent " .. name .. ": " .. tostring(agent) end
  end
  local registry, left_out = core.agent_protocol.new_registry(list)
  for _, problem in ipairs(left_out) do skipped[#skipped + 1] = problem end
  return registry, skipped
end

-- core/sweep.lua: one look at every pane: asks each pane's agent which
-- conversation it runs, and records or forgets it (core/recording.lua).

local shell, recording, rex_server, files = ...

local M = {}

local function log(message) rex.log("info", message) end

-- Asks `agent` which conversation runs in `pane`, checking its answer:
-- { agent, id, cwd }, or nil and why. A broken agent makes only its own panes
-- go unidentified.
local function ask_agent(agent, pane, foreground, peers, host)
  local ok, found, why = pcall(agent.detect, pane, foreground, peers, host)
  if not ok then return nil, "its detect failed: " .. tostring(found) end
  if found and not (type(found) == "table" and agent.is_valid_id(found.id) == true) then
    return nil, "its detect returned an ID its is_valid_id refuses"
  end
  if found then found.agent = agent.name end
  return found, why
end

-- Looks at every pane and records its agent. `sweep` is its kind
-- (recording.SWEEP); a timed sweep also forgets agents that are gone (see
-- recording.note_agent_missing).
function M.run(watcher, sweep)
  local panes, complete = rex_server.list_terminal_panes()
  -- A failed or empty read never replaces what is recorded.
  if not complete or #panes == 0 then return end
  local now = os.time()

  -- Each pane's process and agent, and the panes each agent runs in (its detect's `peers`).
  local observations, peers_by_agent = {}, {}
  for _, pane in ipairs(panes) do
    local process = rex_server.terminal_call(pane, "process")
    local foreground = type(process) == "table" and process.foreground or nil
    local agent = foreground and foreground.pid and watcher.agents.by_program[shell.program_name(foreground)] or nil
    observations[#observations + 1] = { pane = pane, process = process, foreground = foreground, agent = agent }
    if agent then
      peers_by_agent[agent.name] = peers_by_agent[agent.name] or {}
      table.insert(peers_by_agent[agent.name], { pane = pane, foreground = foreground })
    end
  end

  local live_panes, state = {}, watcher.state
  for _, observed in ipairs(observations) do
    local pane, agent = observed.pane, observed.agent
    live_panes[pane.block_id] = true
    local found, why
    if agent then found, why = ask_agent(agent, pane, observed.foreground, peers_by_agent[agent.name], watcher.host) end
    local finding = recording.classify_finding(observed.process ~= nil, agent, found ~= nil)
    if finding == recording.FINDING.AGENT then
      found.session = pane.session
      if recording.record_agent(state, pane.block_id, found, now) then
        log("recorded " .. found.agent .. " " .. found.id .. " in " .. tostring(pane.session))
      end
    elseif finding == recording.FINDING.AGENT_UNIDENTIFIED then
      if why then rex.log("warn", agent.name .. " in " .. tostring(pane.session) .. ": " .. why) end
    elseif finding == recording.FINDING.NO_AGENT then
      -- Recorded for an agent that isn't loaded: this sweep can't see it, so it's kept.
      if not recording.is_of_unloaded_agent(state.panes[pane.block_id], watcher.agents)
        and recording.note_agent_missing(state, pane.block_id, recording.MISSING.AGENT_STOPPED, sweep) then
        log("forgot the agent in " .. tostring(pane.session) .. ": it stopped")
      end
    end -- UNREADABLE: nothing changes
  end
  for block_id in pairs(state.panes) do
    if not live_panes[block_id] and recording.note_agent_missing(state, block_id, recording.MISSING.PANE_CLOSED, sweep) then
      log("forgot the agent in " .. block_id .. ": its pane closed")
    end
  end
  if sweep == recording.SWEEP.TIMED then state.swept_at = now end
  files.write_json(watcher.paths.state_file, state, watcher.pid)
end

return M

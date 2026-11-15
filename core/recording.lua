-- core/recording.lua: the rules for state.json, which conversation each pane
-- runs: what a sweep found, recording it, and when to forget it. Doesn't talk
-- to Rex, so the tests cover it.
--
--   { version, instance_id, swept_at,
--     panes = { [block_id] = { agent, id, cwd, session, seen_at, missed } } }

local restore = ...

local M = {}

M.SWEEP_INTERVAL_SECONDS = 15  -- between timed sweeps of every pane
M.MISSES_BEFORE_FORGETTING = 2 -- timed sweeps in a row an agent must be missing from
M.STATE_VERSION = 1

function M.new_state(instance_id)
  return { version = M.STATE_VERSION, instance_id = instance_id, panes = {} }
end

-- Whether an entry belongs to an agent that isn't loaded, as when its file is
-- broken. Its record is kept as it is until the pane closes, so fixing the file
-- loses nothing.
function M.is_of_unloaded_agent(entry, registry)
  return type(entry) == "table" and type(entry.agent) == "string" and registry.by_name[entry.agent] == nil
end

-- A state read from disk, with anything malformed dropped. Entries of an agent
-- that isn't loaded are kept if they look sound; resuming them fails until it is.
function M.sanitize_state(raw, registry)
  if type(raw) ~= "table" or raw.version ~= M.STATE_VERSION or type(raw.panes) ~= "table" then
    return M.new_state(nil)
  end
  local panes = {}
  for block_id, entry in pairs(raw.panes) do
    local sound = restore.resume_command(entry, registry)
      or (M.is_of_unloaded_agent(entry, registry) and type(entry.id) == "string")
    if type(block_id) == "string" and type(entry) == "table" and sound then
      panes[block_id] = entry
    end
  end
  raw.panes = panes
  return raw
end

-- The state a watcher starts with on server `instance_id`, given `saved`, the
-- sanitized state.json, and `existing_restore`, restore.json. Returns the
-- state, the restore.json to write or nil, and whether to save the state now.
-- On the first look at a new server, what the last one ran is to be restored,
-- unless a watcher started at the same moment wrote that restore already.
function M.start(saved, instance_id, existing_restore)
  if saved.instance_id == instance_id then return saved, nil, false end
  if not saved.instance_id then return M.new_state(instance_id), nil, false end
  local already = type(existing_restore) == "table" and existing_restore.for_instance == instance_id
  local to_restore = not already and { for_instance = instance_id, from_instance = saved.instance_id,
    state = restore.RESTORE_STATE.PENDING, panes = saved.panes, typed = {} } or nil
  return M.new_state(instance_id), to_restore, true
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

-- `agent` is the registered agent of the pane's foreground program, or nil.
function M.classify_finding(process_readable, agent, identified)
  if not process_readable then return M.FINDING.UNREADABLE end
  if not agent then return M.FINDING.NO_AGENT end
  if identified then return M.FINDING.AGENT end
  return M.FINDING.AGENT_UNIDENTIFIED
end

-- Records the agent a sweep found in a pane. Returns true when it's new or changed.
function M.record_agent(state, block_id, found, now)
  local old = state.panes[block_id]
  local changed = not old or old.agent ~= found.agent or old.id ~= found.id
  state.panes[block_id] = { agent = found.agent, id = found.id, cwd = found.cwd,
                            session = found.session, seen_at = now, missed = 0 }
  return changed
end

-- The two kinds of sweep:
--   on_event  soon after a pane's program changes or a pane closes
--   timed     every SWEEP_INTERVAL_SECONDS
M.SWEEP = { ON_EVENT = "on_event", TIMED = "timed" }

-- Why a sweep found no agent in a pane that has one recorded:
--   agent_stopped  the pane is there, running something else
--   pane_closed    the pane is gone
M.MISSING = { AGENT_STOPPED = "agent_stopped", PANE_CLOSED = "pane_closed" }

-- Notes that a sweep found no agent in a pane (`missing` says why; `sweep` is
-- its kind). Only a timed sweep forgets one, and only after
-- MISSES_BEFORE_FORGETTING in a row: stopping Rex closes the agents seconds
-- before the server exits, and the sweeps that triggers must not lose them. A
-- closed pane is forgotten at the first timed sweep. Returns true when the
-- pane's agent was forgotten.
function M.note_agent_missing(state, block_id, missing, sweep)
  local entry = state.panes[block_id]
  if not entry or sweep ~= M.SWEEP.TIMED then return false end
  entry.missed = (entry.missed or 0) + 1
  if missing == M.MISSING.PANE_CLOSED or entry.missed >= M.MISSES_BEFORE_FORGETTING then
    state.panes[block_id] = nil
    return true
  end
  return false
end

return M

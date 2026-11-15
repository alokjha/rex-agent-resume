-- core/status.lua: `mode=status`: prints what is recorded, and how the last
-- restore went.

local recording, restore, files = ...

local M = {}

function M.print(watcher)
  local recorded = recording.sanitize_state(files.read_json(watcher.paths.state_file), watcher.agents)
  print("server " .. tostring(recorded.instance_id) .. ", last timed sweep " ..
    (recorded.swept_at and os.date("%H:%M:%S", recorded.swept_at) or "never"))
  for _, entry in pairs(recorded.panes) do
    print(string.format("  %-20s %-6s %s  %s", tostring(entry.session), entry.agent, entry.id, entry.cwd or ""))
  end

  local last_restore = files.read_json(watcher.paths.restore_file)
  if type(last_restore) ~= "table" or type(last_restore.panes) ~= "table" then return end
  local planned, typed = 0, 0
  for block_id in pairs(last_restore.panes) do
    planned = planned + 1
    if last_restore.typed and last_restore.typed[block_id] then typed = typed + 1 end
  end
  print("last restore (" .. tostring(last_restore.state or restore.RESTORE_STATE.PENDING) .. "): " .. typed .. " of "
    .. planned .. " agent(s) typed, for server " .. tostring(last_restore.for_instance))
  for block_id, why in pairs(type(last_restore.failed) == "table" and last_restore.failed or {}) do
    local entry = last_restore.panes[block_id]
    print("  failed: " .. tostring(entry and entry.session) .. ": " .. tostring(why))
  end
end

return M

-- core/rex_server.lua: what the watcher asks the Rex server: about itself, its
-- terminal panes, and each pane's terminal.

local M = {}

local TERMINAL = "com.superlogical.terminal" -- the Rex block type of a terminal pane

local function call(method, params)
  local result, err = rex.call(method, params or {})
  if result == nil and err then rex.log("warn", method .. ": " .. tostring(err)) end
  return result
end

-- Calls a method of a pane's terminal, such as "process", "title" or "write".
function M.terminal_call(pane, method, params)
  params = params or {}
  params.session_id, params.block_id = pane.session_id, pane.block_id
  return rex.block.call(TERMINAL, method, params)
end

-- An ISO-8601 UTC time ("2026-11-13T15:58:36.49Z") in Unix seconds.
local function iso_to_unix_time(text)
  if type(text) ~= "string" then return nil end
  local year, month, day, hour, minute, second =
    text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then return nil end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  -- Days since 1970-01-01 (Howard Hinnant's days_from_civil).
  if month <= 2 then year = year - 1 end
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local shifted_month = (month + 9) % 12
  local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
  local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
  local days = era * 146097 + day_of_era - 719468
  return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

-- { instance_id, started_at } of the server, or nil.
function M.read_server_info()
  local status = call("server.status")
  if not status or type(status.instance_id) ~= "string" then return nil end
  return { instance_id = status.instance_id, started_at = iso_to_unix_time(status.started_at) or os.time() }
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
function M.list_terminal_panes()
  local list = call("session.list")
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

return M

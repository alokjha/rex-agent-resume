-- agents/codex/database.lua: reading Codex's thread database,
-- ~/.codex/state_N.sqlite. Its format belongs to Codex and can change, so every
-- use of it has a fallback. Used only by agents/codex/codex.lua.

local M = {}

local function sql_quote(text) return "'" .. tostring(text):gsub("'", "''") .. "'" end

local warned = false

-- The newest state database in `codex_home`, or nil.
local function find(host, codex_home)
  local result = host.exec({ "/bin/sh", "-c", 'ls "$1"/state_*.sqlite 2>/dev/null', "sh", codex_home })
  local newest_path, newest_version
  for path in ((result and result.stdout) or ""):gmatch("[^\n]+") do
    local version = tonumber(path:match("state_(%d+)%.sqlite$"))
    if version and (not newest_version or version > newest_version) then
      newest_path, newest_version = path, version
    end
  end
  return newest_path
end

-- Runs `query`, read-only. Codex's database is in WAL mode, and a read-only
-- reader can't create its -shm file, so this fails while no Codex has the
-- database open. Then there is no -wal file either, and reading it as
-- immutable sees everything.
local function run(host, db_path, query)
  local result = host.exec({ "sqlite3", "-readonly", "-json", db_path, query }, { timeout = 5 })
  if not (result and result.ok) and not host.read_file(db_path .. "-wal") then
    local uri = "file:" .. db_path:gsub("[%%?# ]", function(c) return string.format("%%%02X", c:byte()) end)
      .. "?immutable=1"
    result = host.exec({ "sqlite3", "-json", uri, query }, { timeout = 5 })
  end
  return result
end

-- Codex's threads in `folder` written since `started_ms`, or named by
-- `resume_target`, newest first: { { id, name, updated_ms,
-- written_since_start }, ... }; nil when the database can't be read.
function M.threads(host, codex_home, folder, started_ms, resume_target)
  local db_path = find(host, codex_home)
  if not db_path then return nil end
  local also_named = ""
  if resume_target and resume_target.uuid then also_named = " OR id = " .. sql_quote(resume_target.uuid) end
  if resume_target and resume_target.name then also_named = " OR name = " .. sql_quote(resume_target.name) end
  local updated_ms = "COALESCE(updated_at_ms, updated_at * 1000)"
  local query = "SELECT id, COALESCE(name, '') AS name, " .. updated_ms .. " AS updated_ms FROM threads"
    .. " WHERE archived = 0 AND cwd = " .. sql_quote(folder)
    -- Codex's own review threads and the desktop app's aren't a terminal's.
    .. " AND COALESCE(thread_source, 'user') = 'user'"
    .. " AND COALESCE(originator, '') <> 'codex_work_desktop'"
    .. " AND (" .. updated_ms .. " >= " .. string.format("%d", started_ms) .. also_named .. ")"
    .. " ORDER BY updated_ms DESC LIMIT 20"
  local result = run(host, db_path, query)
  if not (result and result.ok) then
    if not warned then
      warned = true
      host.warn("can't read Codex's threads from " .. db_path .. ", using fallbacks: "
        .. tostring(result and result.stderr))
    end
    return nil
  end
  if not result.stdout:find("%S") then return {} end
  local ok, threads = pcall(host.decode_json, result.stdout)
  if not ok or type(threads) ~= "table" then return nil end
  for _, thread in ipairs(threads) do
    thread.written_since_start = (tonumber(thread.updated_ms) or 0) >= started_ms
  end
  return threads
end

return M

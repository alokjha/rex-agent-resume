-- agents/codex.lua: Codex. Codex doesn't say which thread a TUI is on, so it is
-- worked out from Codex's thread database, the TUI's command line and the
-- pane's title. See agents/init.lua.

local lib = ...

local codex = {
  name = "codex",
  programs = { "codex" },
  is_valid_id = lib.is_uuid,
}

function codex.resume_command(id) return "codex resume " .. id end

-- Telling which thread a TUI is on. Private to this agent. -------------------

-- The conversation a codex command line names: `codex [options] resume X`.
-- Returns { uuid = X } or { name = X }, or nil.
local function resume_target_of(argv)
  if type(argv) ~= "table" then return nil end
  for i = 2, #argv do
    if argv[i] == "resume" then
      local target = argv[i + 1]
      if not target or target:sub(1, 1) == "-" then return nil end
      if lib.is_uuid(target) then return { uuid = target } end
      return { name = table.concat(argv, " ", i + 1) }
    elseif argv[i]:sub(1, 1) ~= "-" and argv[i - 1]:sub(1, 1) ~= "-" then
      return nil -- another subcommand, or a prompt (a word after an option is its value)
    end
  end
  return nil
end

-- The thread name Codex shows in its title, "NAME | FOLDER", or the whole title.
local function thread_name_from_title(title)
  if type(title) ~= "string" or title == "" then return nil end
  return title:match("^(.-) | [^|]*$") or title
end

-- Chooses a Codex TUI's thread from `threads`: Codex's threads in its folder
-- that were written since it started (`written_since_start`) or that its
-- command line names (`resume_target`), newest first. `folder_is_shared` says
-- another Codex runs in the same folder. Returns the thread ID, or nil and why.
local function choose_thread(threads, title, resume_target, folder_is_shared)
  if type(threads) ~= "table" or #threads == 0 then return nil end
  local title_name = thread_name_from_title(title)
  local named_in_title = {}
  for _, thread in ipairs(threads) do
    if title_name and thread.name == title_name then named_in_title[#named_in_title + 1] = thread.id end
  end
  if #named_in_title == 1 then return named_in_title[1] end
  if resume_target and not folder_is_shared then
    local newest = threads[1]
    for _, thread in ipairs(threads) do
      local is_target = (resume_target.uuid and thread.id == resume_target.uuid)
        or (resume_target.name and thread.name == resume_target.name)
      -- Unless a newer thread was written since, the one it resumed is it.
      if is_target and (newest.id == thread.id or not newest.written_since_start) then return thread.id end
    end
  end
  if not folder_is_shared then return threads[1].id end
  return nil, "another Codex runs in the same folder and its title doesn't name one thread"
end

-- Of Codex's session_index.jsonl text, the newest ID with this thread name.
local function id_from_index(index_text, thread_name, decode_json)
  if not index_text or not thread_name then return nil end
  local found
  for line in index_text:gmatch("[^\n]+") do
    local ok, indexed = pcall(decode_json, line)
    if ok and type(indexed) == "table" and indexed.thread_name == thread_name and lib.is_uuid(indexed.id) then
      found = indexed.id
    end
  end
  return found
end

-- Codex's thread database ----------------------------------------------------

local function codex_dir(host)
  return host.getenv("CODEX_HOME") or (host.home .. "/.codex")
end

local function sql_quote(text) return "'" .. tostring(text):gsub("'", "''") .. "'" end

local warned_about_db = false

-- Codex's newest state database, ~/.codex/state_N.sqlite. Its format belongs
-- to Codex and can change, so every use of it has a fallback.
local function find_db(host)
  local result = host.exec({ "/bin/sh", "-c", 'ls "$1"/state_*.sqlite 2>/dev/null', "sh", codex_dir(host) })
  local newest_path, newest_version
  for path in ((result and result.stdout) or ""):gmatch("[^\n]+") do
    local version = tonumber(path:match("state_(%d+)%.sqlite$"))
    if version and (not newest_version or version > newest_version) then
      newest_path, newest_version = path, version
    end
  end
  return newest_path
end

-- Codex's threads in `folder` written since `started_ms`, or named by
-- `resume_target`, newest first; nil when the database can't be read.
local function query_threads(host, folder, started_ms, resume_target)
  local db_path = find_db(host)
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
  local result = host.exec({ "sqlite3", "-readonly", "-json", db_path, query }, { timeout = 5 })
  -- Codex's database is in WAL mode. A read-only reader can't create its -shm
  -- file, so it fails while no Codex has the database open. Then there is no
  -- -wal file either, and reading it as immutable sees everything.
  if not (result and result.ok) and not host.read_file(db_path .. "-wal") then
    local uri = "file:" .. db_path:gsub("[%%?# ]", function(c) return string.format("%%%02X", c:byte()) end)
      .. "?immutable=1"
    result = host.exec({ "sqlite3", "-json", uri, query }, { timeout = 5 })
  end
  if not (result and result.ok) then
    if not warned_about_db then
      warned_about_db = true
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

-- The agent ------------------------------------------------------------------

function codex.detect(pane, foreground, peers, host)
  -- With another Codex in the same folder, only the title tells their threads apart.
  local in_folder = 0
  for _, peer in ipairs(peers) do
    if peer.foreground.cwd == foreground.cwd then in_folder = in_folder + 1 end
  end
  local folder_is_shared = in_folder > 1
  local ps = host.exec({ "ps", "-ww", "-o", "etime=,args=", "-p", tostring(foreground.pid) }, { timeout = 5 })
  local age_seconds, argv = lib.parse_ps_line(ps and ps.ok and ps.stdout)
  if not age_seconds then return nil end
  local resume_target = resume_target_of(argv)
  local title_reply = host.terminal_call(pane, "title")
  local title = title_reply and title_reply.title
  local started_ms = (host.now() - age_seconds - 2) * 1000
  local threads = query_threads(host, foreground.cwd, started_ms, resume_target)
  local id, why
  if threads then id, why = choose_thread(threads, title, resume_target, folder_is_shared) end
  if not id and resume_target and resume_target.uuid then id = resume_target.uuid end
  if not id then
    local index_text = host.read_file(codex_dir(host) .. "/session_index.jsonl")
    id = id_from_index(index_text, thread_name_from_title(title), host.decode_json)
      or (resume_target and id_from_index(index_text, resume_target.name, host.decode_json))
  end
  if not id then return nil, why end
  return { id = id, cwd = foreground.cwd }
end

return codex

-- agents/codex/threads.lua: choosing which Codex thread a TUI is on, from the
-- candidates the database gives, the pane's title, and session_index.jsonl.
-- Used only by agents/codex/codex.lua.

local shell = ...

local M = {}

-- The thread name Codex shows in its title, "NAME | FOLDER", or the whole title.
function M.name_from_title(title)
  if type(title) ~= "string" or title == "" then return nil end
  return title:match("^(.-) | [^|]*$") or title
end

-- Chooses a TUI's thread from `threads`: Codex's threads in its folder that
-- were written since it started (`written_since_start`) or that its command
-- line names (`resume_target`), newest first. `folder_is_shared` says another
-- Codex runs in the same folder. Returns the thread ID, or nil and why.
function M.choose(threads, title, resume_target, folder_is_shared)
  if type(threads) ~= "table" or #threads == 0 then return nil end
  local title_name = M.name_from_title(title)
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

-- Of session_index.jsonl's text, the newest ID with this thread name.
function M.id_from_index(index_text, thread_name, decode_json)
  if not index_text or not thread_name then return nil end
  local found
  for line in index_text:gmatch("[^\n]+") do
    local ok, indexed = pcall(decode_json, line)
    if ok and type(indexed) == "table" and indexed.thread_name == thread_name and shell.is_uuid(indexed.id) then
      found = indexed.id
    end
  end
  return found
end

return M

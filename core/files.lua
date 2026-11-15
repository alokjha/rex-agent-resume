-- core/files.lua: reading and writing the watcher's files.

local M = {}

function M.read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

function M.read_json(path)
  local text = M.read_file(path)
  if not text then return nil end
  local ok, value = pcall(rex.json.decode, text)
  return ok and value or nil
end

-- Written whole, to a file only you can read, then renamed over the old one.
-- `writer_pid` names the temporary file: each watcher has its own, as several
-- may run for a moment.
function M.write_json(path, value, writer_pid)
  local temp_path = path .. ".tmp." .. tostring(writer_pid or os.time())
  local file = io.open(temp_path, "w")
  if not file then return rex.log("warn", "can't write " .. temp_path) end
  file:write(rex.json.encode(value, { indent = true }))
  file:close()
  rex.exec({ "chmod", "600", temp_path })
  local ok, err = os.rename(temp_path, path)
  if not ok then rex.log("warn", "can't save " .. path .. ": " .. tostring(err)) end
end

return M

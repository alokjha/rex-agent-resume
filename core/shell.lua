-- core/shell.lua: small helpers about shells and processes, for the core and
-- the agents.

local M = {}

local UUID_PATTERN = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

-- Whether `value` is a UUID: an ID safe to type into a shell.
function M.is_uuid(value)
  return type(value) == "string" and value:find(UUID_PATTERN) ~= nil
end

-- Single-quoted for zsh, bash and fish alike. A backslash inside single quotes
-- means something different to fish, so text holding one is refused.
function M.shell_quote(text)
  text = tostring(text)
  if text:find("\\", 1, true) then return nil end
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

-- A process's program name, without its folder or a login shell's leading "-".
function M.program_name(process_info)
  if type(process_info) ~= "table" then return nil end
  local name = (process_info.argv0 or process_info.name or ""):match("([^/]+)$") or ""
  return (name:gsub("^%-", ""))
end

return M

-- agents/codex/command_line.lua: what a Codex process's command line says: how
-- long it has run, and which conversation `codex resume` named. Used only by
-- agents/codex/codex.lua.

local shell = ...

local M = {}

-- `ps -o etime=` ("[[dd-]hh:]mm:ss") in seconds.
local function parse_elapsed_time(text)
  if type(text) ~= "string" then return nil end
  text = text:match("^%s*(.-)%s*$")
  local days, clock = text:match("^(%d+)%-(.+)$")
  clock = clock or text
  local fields = {}
  for field in clock:gmatch("[^:]+") do
    if not field:find("^%d+$") then return nil end
    fields[#fields + 1] = tonumber(field)
  end
  if #fields < 2 or #fields > 3 or (days and #fields ~= 3) then return nil end
  local hours = #fields == 3 and fields[1] or 0
  return (tonumber(days) or 0) * 86400 + hours * 3600 + fields[#fields - 1] * 60 + fields[#fields]
end

-- How long process `pid` has run, in seconds, and its arguments as words, or
-- nil. ps joins arguments with spaces, so an argument holding one comes back split.
function M.read(host, pid)
  local ps = host.exec({ "ps", "-ww", "-o", "etime=,args=", "-p", tostring(pid) }, { timeout = 5 })
  local line = ps and ps.ok and ps.stdout
  if type(line) ~= "string" then return nil end
  local elapsed, command_line = line:match("^%s*(%S+)%s+(.-)%s*$")
  local age_seconds = parse_elapsed_time(elapsed)
  if not age_seconds then return nil end
  local argv = {}
  for word in command_line:gmatch("%S+") do argv[#argv + 1] = word end
  return age_seconds, argv
end

-- The conversation a command line names: `codex [options] resume X`.
-- Returns { uuid = X } or { name = X }, or nil.
function M.resume_target(argv)
  if type(argv) ~= "table" then return nil end
  for i = 2, #argv do
    if argv[i] == "resume" then
      local target = argv[i + 1]
      if not target or target:sub(1, 1) == "-" then return nil end
      if shell.is_uuid(target) then return { uuid = target } end
      return { name = table.concat(argv, " ", i + 1) }
    elseif argv[i]:sub(1, 1) ~= "-" and argv[i - 1]:sub(1, 1) ~= "-" then
      return nil -- another subcommand, or a prompt (a word after an option is its value)
    end
  end
  return nil
end

return M

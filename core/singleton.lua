-- core/singleton.lua: one watcher at a time. The newest replaces an older one,
-- which may be left from a server that has stopped, waiting on a connection
-- that will never answer. The watcher is the one whose pid is in watcher.pid.

local files = ...

local M = {}

-- The pid of the `rex do` process running the script.
local function find_own_pid()
  local result = rex.exec({ "/bin/sh", "-c", "echo $PPID" })
  return result and result.ok and tonumber(result.stdout:match("%d+"))
end

-- Whether `pid` is a watcher running `script` (not a mode=resume or mode=status run).
local function is_running_watcher(pid, script)
  local result = rex.exec({ "ps", "-ww", "-o", "args=", "-p", tostring(pid) })
  return result and result.ok and result.stdout:find(script, 1, true) ~= nil
    and not result.stdout:find("mode=", 1, true)
end

-- The pid in watcher.pid, or nil.
function M.pid_file_owner(watcher) return tonumber(files.read_file(watcher.paths.pid_file) or "") end

-- Makes this watcher the one: stops an older watcher running `script`, and
-- writes this one's pid, which it sets as watcher.pid.
function M.take_over(watcher, script)
  watcher.pid = find_own_pid()
  local older_pid = M.pid_file_owner(watcher)
  if older_pid and older_pid ~= watcher.pid and is_running_watcher(older_pid, script) then
    rex.exec({ "kill", tostring(older_pid) })
    rex.log("info", "replaced the older watcher " .. older_pid)
  end
  if watcher.pid then
    local file = io.open(watcher.paths.pid_file, "w")
    if file then file:write(tostring(watcher.pid)) file:close() end
  end
end

-- Whether this watcher is still the one. Config loads can start several at
-- once; all but the one whose pid is in the file stop.
function M.is_the_watcher(watcher) return watcher.pid ~= nil and M.pid_file_owner(watcher) == watcher.pid end

return M

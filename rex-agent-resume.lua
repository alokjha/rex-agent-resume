-- rex-agent-resume.lua: loaded by init.lua with dofile. Starts watcher.lua in
-- the background each time the Rex server loads its config, and adds the
-- resume_agents action. https://github.com/alokjha/rex-agent-resume

local here = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."
local HOME = os.getenv("HOME") or ""
local STATE = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-agent-resume"
local WATCHER = here .. "/watcher.lua"

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

-- The server may load its config with a PATH that has no rex on it.
local function rex_bin()
  local dir = os.getenv("REX_BIN_DIR")
  if dir and exists(dir .. "/rex") then return dir .. "/rex" end
  local app = HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if exists(app) then return app end
  return "rex"
end
local REX = rex_bin()

-- Waits for the server to answer, keeps the log under 1 MB, then runs the
-- watcher. --autostart=false so it never starts a server of its own. The
-- watcher makes sure only one copy runs.
rex.exec.start({ "/bin/sh", "-c", [[
  mkdir -p "$3" && chmod 700 "$3"
  log="$3/watcher.log"
  if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt 1048576 ]; then mv "$log" "$log.1"; fi
  i=0
  while [ $i -lt 30 ]; do
    if "$1" --autostart=false server status >/dev/null 2>&1; then
      exec "$1" --autostart=false do --all "$2" "state=$3" >>"$log" 2>&1
    fi
    i=$((i + 1)); sleep 1
  done
]], "rex-agent-resume", REX, WATCHER, STATE }, { detach = true })

rex.action{
  name = "resume_agents",
  title = "Resume Agents",
  description = "Resume the Claude Code and Codex conversations the last Rex server ran, in panes that are back at a shell prompt.",
  run = function()
    local r = rex.exec({ REX, "--autostart=false", "do", "--all", WATCHER, "mode=resume", "state=" .. STATE },
      { timeout = 30 })
    return r and r.stdout
  end,
}

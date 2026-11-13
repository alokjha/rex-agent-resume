-- rex-agent-resume.lua: loaded by init.lua with dofile. Starts watcher.lua in
-- the background each time the Rex server loads its config, and adds the
-- resume_agents action. https://github.com/alokjha/rex-agent-resume

local MODULE_DIR = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."
local HOME = os.getenv("HOME") or ""
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/rex-agent-resume"
local WATCHER_SCRIPT = MODULE_DIR .. "/watcher.lua"

local function file_exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

-- The server may load its config with a PATH that has no rex on it.
local function find_rex_binary()
  local bin_dir = os.getenv("REX_BIN_DIR")
  if bin_dir and file_exists(bin_dir .. "/rex") then return bin_dir .. "/rex" end
  local app_binary = HOME .. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if file_exists(app_binary) then return app_binary end
  return "rex"
end
local REX_BINARY = find_rex_binary()

-- Waits for the server to answer, keeps the log under 1 MB, then runs the
-- watcher. --autostart=false so it never starts a server of its own. The
-- watcher makes sure only one copy runs.
rex.exec.start({ "/bin/sh", "-c", [[
  rex_binary=$1 watcher_script=$2 state_dir=$3
  mkdir -p "$state_dir" && chmod 700 "$state_dir"
  log_file="$state_dir/watcher.log"
  if [ -f "$log_file" ] && [ "$(wc -c < "$log_file")" -gt 1048576 ]; then mv "$log_file" "$log_file.1"; fi
  attempts=0
  while [ $attempts -lt 30 ]; do
    if "$rex_binary" --autostart=false server status >/dev/null 2>&1; then
      exec "$rex_binary" --autostart=false do --all "$watcher_script" "state=$state_dir" >>"$log_file" 2>&1
    fi
    attempts=$((attempts + 1)); sleep 1
  done
]], "rex-agent-resume", REX_BINARY, WATCHER_SCRIPT, STATE_DIR }, { detach = true })

rex.action{
  name = "resume_agents",
  title = "Resume Agents",
  description = "Resume the Claude Code and Codex conversations the last Rex server ran, in panes that are back at a shell prompt.",
  run = function()
    local result = rex.exec({ REX_BINARY, "--autostart=false", "do", "--all", WATCHER_SCRIPT,
      "mode=resume", "state=" .. STATE_DIR }, { timeout = 30 })
    return result and result.stdout
  end,
}

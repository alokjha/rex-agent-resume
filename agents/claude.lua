-- agents/claude.lua: Claude Code. Each running Claude writes
-- ~/.claude/sessions/<pid>.json naming its conversation. See agents/init.lua.

local lib = ...

local claude_ids_with_transcript = {}

local function claude_dir(host)
  return host.getenv("CLAUDE_CONFIG_DIR") or (host.home .. "/.claude")
end

local claude = {
  name = "claude",
  programs = { "claude" },
  is_valid_id = lib.is_uuid,
}

function claude.resume_command(id) return "claude --resume " .. id end

function claude.detect(_, foreground, _, host)
  local dir = claude_dir(host)
  local session_file = host.read_json(dir .. "/sessions/" .. foreground.pid .. ".json")
  if type(session_file) ~= "table" or not lib.is_uuid(session_file.sessionId) then return nil end
  if session_file.pid and session_file.pid ~= foreground.pid then return nil end
  local id = session_file.sessionId
  -- A conversation gets a transcript with its first message; before that there
  -- is nothing to resume.
  if not claude_ids_with_transcript[id] then
    local result = host.exec({ "/bin/sh", "-c",
      'for f in "$1"/projects/*/"$2".jsonl; do [ -e "$f" ] && exit 0; done; exit 1',
      "sh", dir, id })
    if not (result and result.ok) then return nil end
    claude_ids_with_transcript[id] = true
  end
  return { id = id, cwd = session_file.cwd or foreground.cwd }
end

return claude

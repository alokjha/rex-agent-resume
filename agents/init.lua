-- agents/init.lua: the agents rex-agent-resume can resume, one file each in
-- this folder. To add one, write agents/<name>.lua and add <name> to AGENTS.
--
-- An agent file is loaded with lib.lua as its argument (`local lib = ...`) and
-- returns a table:
--
--   name            the agent's name, as recorded in state.json: letters,
--                   digits, "_" or "-"
--   programs        the foreground program names that mean this agent runs,
--                   as lib.program_name gives them, e.g. { "claude" }
--   is_valid_id(id) whether `id` is a conversation ID of this agent. The ID is
--                   typed into a shell, so accept only what is safe there.
--   resume_command(id)
--                   the shell command that resumes conversation `id` in its
--                   folder, e.g. "claude --resume " .. id
--   detect(pane, foreground, peers, host)
--                   which conversation runs in a pane whose foreground process
--                   is this agent: { id = ..., cwd = ... }, or nil and why
--                   (nil alone when there is nothing to resume yet). The
--                   record is kept while it returns nil.
--
-- All five are required, and any other field is refused, so a misspelled one
-- shows when the watcher starts. The core calls only these. Anything else an
-- agent needs is `local` to its file, and its tests go through the five.
--
-- `pane` is { block_id, session_id, session }. `foreground` is the pane's
-- foreground process from Rex: { pid, cwd, argv0, name, ... }. `peers` is
-- every pane this agent runs in at this sweep, this one too, as
-- { { pane, foreground }, ... }: Codex uses it to see whether another Codex
-- shares the folder. `host` is
-- what the watcher lends an agent (the `host` table in watcher.lua):
--   home, getenv(name), now(), read_file(path), read_json(path),
--   decode_json(text), exec(argv, options), warn(message),
--   terminal_call(pane, method, params)
-- Agents use only `host`, never `rex` itself, so tests can pass a fake one.

local AGENTS = { "claude", "codex" }

local dir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("^(.*)/[^/]*$") or "."

return function(lib)
  local list = {}
  for _, name in ipairs(AGENTS) do
    local path = dir .. "/" .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("can't load agent " .. name .. ": " .. tostring(err)) end
    list[#list + 1] = chunk(lib)
  end
  return lib.new_registry(list)
end

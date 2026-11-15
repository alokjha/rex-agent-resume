-- agents/codex/codex.lua: Codex. Implements the Agent protocol
-- (core/agent_protocol.lua). Codex doesn't say which thread a TUI is on, so
-- detect works it out from Codex's thread database, the TUI's command line and
-- the pane's title, with the helpers beside this file.

local shell, folder = ...

local function helper(name) return assert(loadfile(folder .. "/" .. name .. ".lua"))(shell) end
local command_line = helper("command_line")
local threads = helper("threads")
local database = helper("database")

local function codex_home(host)
  return host.getenv("CODEX_HOME") or (host.home .. "/.codex")
end

local codex = {
  name = "codex",
  programs = { "codex" },
}

function codex.is_valid_id(id) return shell.is_uuid(id) end

function codex.resume_command(id) return "codex resume " .. id end

function codex.detect(pane, foreground, peers, host)
  -- With another Codex in the same folder, only the title tells their threads apart.
  local codex_panes_in_folder = 0
  for _, peer in ipairs(peers) do
    if peer.foreground.cwd == foreground.cwd then codex_panes_in_folder = codex_panes_in_folder + 1 end
  end
  local folder_is_shared = codex_panes_in_folder > 1

  local age_seconds, argv = command_line.read(host, foreground.pid)
  if not age_seconds then return nil end
  local resume_target = command_line.resume_target(argv)
  local title_reply = host.terminal_call(pane, "title")
  local title = title_reply and title_reply.title

  -- The database's threads in this folder since the TUI started (2 seconds' slack).
  local started_ms = (host.now() - age_seconds - 2) * 1000
  local candidates = database.threads(host, codex_home(host), foreground.cwd, started_ms, resume_target)
  local id, why
  if candidates then id, why = threads.choose(candidates, title, resume_target, folder_is_shared) end

  -- Without the database: the command line, then the title's name in the index.
  if not id and resume_target and resume_target.uuid then id = resume_target.uuid end
  if not id then
    local index_text = host.read_file(codex_home(host) .. "/session_index.jsonl")
    id = threads.id_from_index(index_text, threads.name_from_title(title), host.decode_json)
      or (resume_target and threads.id_from_index(index_text, resume_target.name, host.decode_json))
  end
  if not id then return nil, why end
  return { id = id, cwd = foreground.cwd }
end

return codex

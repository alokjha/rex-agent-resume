-- core/restore.lua: the rules for typing the last server's conversations back
-- into their panes. Doesn't talk to Rex, so the tests cover it.

local shell = ...

local M = {}

M.WINDOW_SECONDS = 120 -- after a server starts, how long panes may be typed into
M.TYPEABLE_SHELLS = { zsh = true, bash = true, fish = true }

-- The command that resumes an entry's conversation in its folder, or nil and
-- why. `registry` is the registry of agents (core/agent_protocol.lua). A
-- broken agent makes only its own entries fail.
function M.resume_command(entry, registry)
  if type(entry) ~= "table" then return nil, "it isn't a record" end
  local agent = registry.by_name[entry.agent]
  if not agent then return nil, "agent " .. tostring(entry.agent) .. " isn't loaded (see watcher.log)" end
  local ok, valid = pcall(agent.is_valid_id, entry.id)
  if not ok then return nil, tostring(valid) end
  if not valid then return nil, "its conversation ID isn't one of " .. agent.name .. "'s" end
  local made, command = pcall(agent.resume_command, entry.id)
  if not made then return nil, tostring(command) end
  if entry.cwd then
    local quoted_folder = shell.shell_quote(entry.cwd)
    if not quoted_folder then return nil, "its folder has a backslash" end
    command = "cd " .. quoted_folder .. " && " .. command
  end
  return command
end

-- What is typed into a pane to run `command`: Ctrl-U first, which clears
-- anything left on the line in zsh, bash and fish (in emacs and vi insert keys
-- alike), then the command and Enter.
function M.keystrokes_for(command)
  return "\21" .. command .. "\r"
end

-- Whether a pane is at its shell: its foreground process is the program Rex
-- started (the terminal's child, often `login`) or that program's child.
-- `process` is the terminal's `process` reply.
function M.is_at_shell(process)
  if type(process) ~= "table" then return false end
  local foreground, child = process.foreground, process.child
  if type(foreground) ~= "table" or type(child) ~= "table" or not foreground.pid then return false end
  if foreground.pid == child.pid then return true end
  local parent = type(process.ancestors) == "table" and process.ancestors[1]
  return type(parent) == "table" and parent.pid == child.pid
end

-- The last non-blank line of a pane's screen: its prompt line, once the prompt
-- is drawn. Watching it stay the same shows nothing is being typed.
function M.last_screen_line(screen_text)
  if type(screen_text) ~= "string" then return nil end
  screen_text = screen_text:gsub("[\r\n%s]+$", "")
  return screen_text:match("([^\n]*)$")
end

-- The panes to type into after a restart, sorted by block ID, with one pane per
-- conversation: { { block_id, entry }, ... }. `previous_state` is what the last
-- server left.
function M.plan(previous_state)
  local block_ids, plan, planned = {}, {}, {}
  for block_id in pairs(previous_state.panes or {}) do block_ids[#block_ids + 1] = block_id end
  table.sort(block_ids)
  for _, block_id in ipairs(block_ids) do
    local entry = previous_state.panes[block_id]
    local conversation = entry.agent .. " " .. entry.id
    if not planned[conversation] then
      planned[conversation] = true
      plan[#plan + 1] = { block_id = block_id, entry = entry }
    end
  end
  return plan
end

-- One pane ---------------------------------------------------------------------
--
-- Each pane in a restore moves through these states, one step per look:
--
--   waiting ──prompt line read──▶ prompt_seen ──same line a second later──▶ typed
--      ▲                              │
--      └──────── anything else ───────┘
--
-- and from waiting or prompt_seen to the other final states:
--   already_running  the agent runs in the pane already
--   typed_elsewhere  another watcher typed it (restore.json says so)
--   failed           it can't be typed into; `why` says why

M.PANE_STATE = {
  WAITING = "waiting",
  PROMPT_SEEN = "prompt_seen",
  TYPED = "typed",
  ALREADY_RUNNING = "already_running",
  TYPED_ELSEWHERE = "typed_elsewhere",
  FAILED = "failed",
}
local PANE_STATE = M.PANE_STATE

function M.is_final_pane_state(state_name)
  return state_name == PANE_STATE.TYPED or state_name == PANE_STATE.ALREADY_RUNNING
    or state_name == PANE_STATE.TYPED_ELSEWHERE or state_name == PANE_STATE.FAILED
end

-- The next state of a pane in a restore, given what one look at it found.
-- `pane` is { state, prompt_line }. `look` is:
--   typed_elsewhere  restore.json marks the pane typed by another watcher
--   pane_exists      the pane is on the server
--   agent_running    its foreground program is the recorded agent's
--   at_shell         its foreground is the shell Rex started
--   shell            that shell's name
--   editor_ready     the shell's line editor is reading keys
--   prompt_line      the last line of its screen
-- Returns the new { state, prompt_line, why }, and true when the resume
-- command is to be typed now.
function M.next_pane_state(pane, look)
  local function to(state_name, extra)
    local next_pane = { state = state_name }
    for k, v in pairs(extra or {}) do next_pane[k] = v end
    return next_pane
  end
  if M.is_final_pane_state(pane.state) then return pane, false end
  if look.typed_elsewhere then return to(PANE_STATE.TYPED_ELSEWHERE), false end
  if not look.pane_exists then return to(PANE_STATE.WAITING), false end
  if look.agent_running then return to(PANE_STATE.ALREADY_RUNNING), false end
  if not look.at_shell then return to(PANE_STATE.WAITING), false end
  if not M.TYPEABLE_SHELLS[look.shell] then
    return to(PANE_STATE.FAILED, { why = "its shell " .. tostring(look.shell) .. " isn't zsh, bash or fish" }), false
  end
  local line = look.editor_ready and look.prompt_line or nil
  if not line or line == "" then return to(PANE_STATE.WAITING), false end
  if pane.state == PANE_STATE.PROMPT_SEEN and pane.prompt_line == line then return to(PANE_STATE.TYPED), true end
  return to(PANE_STATE.PROMPT_SEEN, { prompt_line = line }), false
end

-- The whole restore ----------------------------------------------------------
--
-- restore.json's `state`:
--
--   pending ──every pane final, or the window ends──▶ finished
--
-- A finished restore is never run again, even by a watcher started later in
-- the window (a config reload), so failures aren't retried or reported twice.
M.RESTORE_STATE = { PENDING = "pending", FINISHED = "finished" }

-- Whether a watcher on server `instance_id` should run `restore` at time `now`,
-- and if not, why. A restore.json from before `state` existed counts as pending.
function M.should_run(restore, instance_id, now, deadline)
  if type(restore) ~= "table" then return false, "nothing to restore" end
  if restore.for_instance ~= instance_id then return false, "it is for another server" end
  if (restore.state or M.RESTORE_STATE.PENDING) ~= M.RESTORE_STATE.PENDING then return false, "it finished" end
  if now > deadline then return false, "the restore window has ended" end
  return true
end

return M

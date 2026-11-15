-- core/resume.lua: types each planned conversation back into its pane once the
-- pane is at a fresh shell prompt, stepping every pane through
-- restore.PANE_STATE once a second.

local shell, restore, rex_server, files, PHASE = ...

local M = {}

local PANE_STATE = restore.PANE_STATE

local function log(message) rex.log("info", message) end

local function applescript_string(text)
  return '"' .. text:gsub('[\\"]', "\\%0"):gsub("%s+", " ") .. '"'
end

local function notify(watcher, text)
  rex.log("warn", text)
  if not watcher.notify_on_failure then return end
  rex.exec({ "/usr/bin/osascript", "-e",
    "display notification " .. applescript_string(text) .. ' with title "rex-agent-resume"' })
end

-- Looks at a pane once, for restore.next_pane_state.
local function look_at_pane(watcher, pane, entry, typed_on_disk)
  local look = { typed_elsewhere = typed_on_disk, pane_exists = pane ~= nil }
  if not pane then return look end
  local process = rex_server.terminal_call(pane, "process")
  local foreground = type(process) == "table" and process.foreground
  if not foreground then return look end
  local running = watcher.agents.by_program[shell.program_name(foreground)]
  look.agent_running = running ~= nil and running.name == entry.agent
  look.at_shell = restore.is_at_shell(process)
  look.shell = shell.program_name(foreground)
  if look.at_shell and restore.TYPEABLE_SHELLS[look.shell] then
    local input_mode = rex_server.terminal_call(pane, "input_mode")
    look.editor_ready = input_mode and input_mode.canonical == false or false
    if look.editor_ready then
      local screen = rex_server.terminal_call(pane, "format", { trim = true })
      look.prompt_line = screen and restore.last_screen_line(screen.content)
    end
  end
  return look
end

-- How a restore was started:
--   after_restart  by the watcher, once per new server: keeps restore.json up
--                  to date and notifies about failures
--   by_hand        by the Resume Agents action: leaves restore.json as it is
--                  and prints what it did
M.STARTED = { AFTER_RESTART = "after_restart", BY_HAND = "by_hand" }

-- Runs a restore. `last_restore` is restore.json: { for_instance, state,
-- panes, typed, failed }. `options` is { started, deadline, on_done }:
-- how it was started (M.STARTED), when to give up, and what runs at the end.
function M.run(watcher, last_restore, options)
  local by_hand = options.started == M.STARTED.BY_HAND
  local deadline, on_done = options.deadline, options.on_done
  local restore_file = watcher.paths.restore_file
  local panes = {} -- block_id -> { entry, command, state, prompt_line, why }
  for _, planned in ipairs(restore.plan(last_restore)) do
    if not last_restore.typed[planned.block_id] then
      local command, why = restore.resume_command(planned.entry, watcher.agents)
      panes[planned.block_id] = { entry = planned.entry, command = command,
                                  state = command and PANE_STATE.WAITING or PANE_STATE.FAILED, why = why }
    end
  end

  local function describe(pane) return pane.entry.agent .. " in " .. tostring(pane.entry.session) end

  local function mark_typed(block_id)
    last_restore.typed[block_id] = os.time()
    if not by_hand then files.write_json(restore_file, last_restore, watcher.pid) end
  end

  local function finish()
    local failures, counts = {}, {}
    last_restore.failed = {}
    for block_id, pane in pairs(panes) do
      if not restore.is_final_pane_state(pane.state) then
        pane.state, pane.why = PANE_STATE.FAILED, "its pane wasn't at a shell prompt in time"
      end
      counts[pane.state] = (counts[pane.state] or 0) + 1
      if pane.state == PANE_STATE.FAILED then
        failures[#failures + 1] = describe(pane) .. ": " .. pane.why
        last_restore.failed[block_id] = pane.why
      end
    end
    if by_hand then
      -- The action shows its output; a notification for each busy pane would be noise.
      print(string.format("resumed %d, already running %d, not resumed %d",
        counts[PANE_STATE.TYPED] or 0, counts[PANE_STATE.ALREADY_RUNNING] or 0, #failures))
      for _, failure in ipairs(failures) do print("  " .. failure) end
    else
      last_restore.state = restore.RESTORE_STATE.FINISHED
      files.write_json(restore_file, last_restore, watcher.pid)
      if #failures > 0 then
        notify(watcher, "Couldn't resume " .. #failures .. " agent(s): " .. table.concat(failures, "; "))
      end
    end
    if on_done then on_done() end
  end

  local function step()
    if watcher.phase == PHASE.STOPPED then return end
    local all_final = true
    for _, pane in pairs(panes) do
      if not restore.is_final_pane_state(pane.state) then all_final = false end
    end
    if all_final or os.time() > deadline then return finish() end

    local live_panes = {}
    for _, live_pane in ipairs((rex_server.list_terminal_panes())) do live_panes[live_pane.block_id] = live_pane end
    -- What another watcher has typed: restore.json as it is on disk now.
    local restore_on_disk = not by_hand and files.read_json(restore_file)
    local typed_on_disk = type(restore_on_disk) == "table" and type(restore_on_disk.typed) == "table"
      and restore_on_disk.typed or {}

    for block_id, pane in pairs(panes) do
      if not restore.is_final_pane_state(pane.state) then
        local live_pane = live_panes[block_id]
        local look = look_at_pane(watcher, live_pane, pane.entry, typed_on_disk[block_id] ~= nil)
        local next_pane, type_now = restore.next_pane_state(pane, look)
        pane.state, pane.prompt_line, pane.why = next_pane.state, next_pane.prompt_line, next_pane.why
        if type_now then
          mark_typed(block_id) -- before typing, so a pane is never typed into twice
          rex_server.terminal_call(live_pane, "write", { data = restore.keystrokes_for(pane.command) })
          log("resumed " .. pane.entry.agent .. " " .. pane.entry.id .. " in " .. tostring(pane.entry.session))
        elseif pane.state == PANE_STATE.ALREADY_RUNNING then
          mark_typed(block_id)
          log(describe(pane) .. " already runs")
        end
      end
    end
    rex.after(1, step)
  end
  step()
end

return M

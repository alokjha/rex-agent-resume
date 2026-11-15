-- Tests for core/restore.lua: when and what is typed back into a pane.

return function(t, core)
  local restore, fakes = core.restore, core.fakes
  local A, B = fakes.A, fakes.B
  local agents = fakes.registry()

  t("resume_command: what is typed, and when it is refused", function(eq)
    eq(restore.resume_command({ agent = "alpha", id = B, cwd = "/it's" }, agents), "cd '/it'\\''s' && alpha --resume " .. B)
    eq(restore.resume_command({ agent = "beta", id = A .. "; rm -rf ~" }, agents), nil) -- the agent refuses the ID
    eq(restore.resume_command({ agent = "gamma", id = A }, agents), nil)                -- its agent isn't loaded
    eq(restore.resume_command({ agent = "alpha", id = B, cwd = "a\\b" }, agents), nil)  -- fish reads \\ differently
    local broken = { name = "broken", programs = { "broken" }, is_valid_id = core.shell.is_uuid,
      resume_command = function() error("oops") end, detect = function() end }
    eq(restore.resume_command({ agent = "broken", id = A }, core.agent_protocol.new_registry({ broken })), nil) -- only its entry fails
    eq(restore.keystrokes_for("ls"), "\21ls\r")                                     -- Ctrl-U clears the line first
  end)

  t("is_at_shell", function(eq)
    local login = { pid = 10, name = "login" }
    eq(restore.is_at_shell({ child = login, foreground = { pid = 11, name = "zsh" },
                      ancestors = { { pid = 10 } } }), true)
    eq(restore.is_at_shell({ child = login, foreground = { pid = 12, name = "alpha" },
                      ancestors = { { pid = 11 }, { pid = 10 } } }), false)
    eq(restore.is_at_shell({ child = { pid = 11 }, foreground = { pid = 11 } }), true)
    eq(restore.is_at_shell(nil), false)
  end)

  t("plan: one pane per conversation", function(eq)
    local plan = restore.plan({ panes = {
      b2 = { agent = "alpha", id = B }, b1 = { agent = "alpha", id = B }, b3 = { agent = "beta", id = A } } })
    eq(#plan, 2)
    eq(plan[1].block_id, "b1")
    eq(plan[2].block_id, "b3")
  end)

  t("next_pane_state: a steady prompt is typed once", function(eq)
    local S = restore.PANE_STATE
    local ready = { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = true, prompt_line = "~ ❯" }
    local pane, type_now = restore.next_pane_state({ state = S.WAITING }, ready)
    eq(pane.state, S.PROMPT_SEEN)
    eq(type_now, false)
    pane, type_now = restore.next_pane_state(pane, ready)       -- same line a second later
    eq(pane.state, S.TYPED)
    eq(type_now, true)
    local again
    pane, again = restore.next_pane_state(pane, ready)          -- final: stays typed, never again
    eq(pane.state, S.TYPED)
    eq(again, false)
  end)

  t("next_pane_state: a changing or missing prompt waits", function(eq)
    local S = restore.PANE_STATE
    local seen = { state = S.PROMPT_SEEN, prompt_line = "~ ❯" }
    local base = { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = true }
    base.prompt_line = "~ ❯ cl"                             -- someone is typing
    local pane, type_now = restore.next_pane_state(seen, base)
    eq(pane.state, S.PROMPT_SEEN)
    eq(pane.prompt_line, "~ ❯ cl")
    eq(type_now, false)
    eq(restore.next_pane_state(seen, { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = false,
                                    prompt_line = "~ ❯" }).state, S.WAITING)  -- editor not reading keys
    eq(restore.next_pane_state(seen, { pane_exists = true, at_shell = false }).state, S.WAITING)
    eq(restore.next_pane_state(seen, { pane_exists = false }).state, S.WAITING)
  end)

  t("next_pane_state: final states", function(eq)
    local S = restore.PANE_STATE
    local waiting = { state = S.WAITING }
    eq(restore.next_pane_state(waiting, { pane_exists = true, agent_running = true }).state, S.ALREADY_RUNNING)
    eq(restore.next_pane_state(waiting, { typed_elsewhere = true, pane_exists = true }).state, S.TYPED_ELSEWHERE)
    local failed = restore.next_pane_state(waiting, { pane_exists = true, at_shell = true, shell = "sh" })
    eq(failed.state, S.FAILED)
    eq(type(failed.why), "string")
  end)

  t("should_run: a finished restore never runs again", function(eq)
    local R = restore.RESTORE_STATE
    eq(restore.should_run({ for_instance = "i2", state = R.PENDING }, "i2", 100, 200), true)
    eq(restore.should_run({ for_instance = "i2" }, "i2", 100, 200), true)  -- written before `state` existed
    eq(restore.should_run({ for_instance = "i2", state = R.FINISHED }, "i2", 100, 200), false)
    eq(restore.should_run({ for_instance = "i1", state = R.PENDING }, "i2", 100, 200), false)
    eq(restore.should_run({ for_instance = "i2", state = R.PENDING }, "i2", 300, 200), false)
    eq(restore.should_run(nil, "i2", 100, 200), false)
  end)
end

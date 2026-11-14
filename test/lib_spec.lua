-- Tests for lib.lua, the core. Run with any Lua 5.1+:  lua test/run.lua
-- or inside Rex's own Lua:                              rex do test/run.lua
-- The core knows no agent, so these use made-up ones, not those in agents/.

return function(t, lib)
  local A = "0193f2a4-5b6c-7d8e-9f01-23456789abcd"
  local B = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"

  -- A made-up agent that takes UUIDs and resumes with "<name> --resume <id>".
  local function fake_agent(name, programs)
    return { name = name, programs = programs or { name }, is_valid_id = lib.is_uuid,
             resume_command = function(id) return name .. " --resume " .. id end, detect = function() end }
  end
  local agents = lib.new_registry({ fake_agent("alpha"), fake_agent("beta") })

  t("is_uuid", function(eq)
    eq(lib.is_uuid(A), true)
    eq(lib.is_uuid("newAppIdea"), false)
    eq(lib.is_uuid(A .. "; rm -rf ~"), false)
  end)

  t("shell_quote", function(eq)
    eq(lib.shell_quote("/a b"), "'/a b'")
    eq(lib.shell_quote("it's"), "'it'\\''s'")
    eq(lib.shell_quote("a\\b"), nil)
  end)

  t("new_registry: a malformed or clashing agent is refused", function(eq)
    local registry = lib.new_registry({ fake_agent("a", { "a", "a2" }), fake_agent("b", { "b" }) })
    eq(registry.by_program.a2.name, "a")
    eq(#registry.list, 2)
    local function refused(list) return not pcall(lib.new_registry, list) end
    eq(refused({ fake_agent("a", { "x" }), fake_agent("a", { "y" }) }), true)  -- the same name twice
    eq(refused({ fake_agent("a", { "x" }), fake_agent("b", { "x" }) }), true)  -- the same program twice
    eq(refused({ fake_agent("a b", { "x" }) }), true)                     -- a name that isn't a word
    eq(refused({ fake_agent("a", {}) }), true)                            -- no programs
    local no_detect = fake_agent("a", { "a" })
    no_detect.detect = nil
    eq(refused({ no_detect }), true)
    local misspelled = fake_agent("a", { "a" })
    misspelled.resume_comand = function() end
    eq(refused({ misspelled }), true)
  end)

  t("resume_command", function(eq)
    eq(lib.resume_command({ agent = "alpha", id = B, cwd = "/p q" }, agents), "cd '/p q' && alpha --resume " .. B)
    eq(lib.resume_command({ agent = "beta", id = A }, agents), "beta --resume " .. A)
    eq(lib.resume_command({ agent = "beta", id = "x" }, agents), nil)        -- the agent refuses the ID
    eq(lib.resume_command({ agent = "vim", id = A }, agents), nil)           -- no such agent
    eq(lib.resume_command({ agent = "alpha", id = B, cwd = "a\\b" }, agents), nil)
    eq(lib.keystrokes_for("ls"), "\21ls\r")
  end)

  t("parse_elapsed_time", function(eq)
    eq(lib.parse_elapsed_time("  01:05"), 65)
    eq(lib.parse_elapsed_time("02:01:05"), 7265)
    eq(lib.parse_elapsed_time("3-02:01:05"), 3 * 86400 + 7265)
    eq(lib.parse_elapsed_time("x"), nil)
  end)

  t("iso_to_unix_time", function(eq)
    eq(lib.iso_to_unix_time("1970-01-02T00:00:01Z"), 86401)
    eq(lib.iso_to_unix_time("2026-11-13T15:58:36.494463Z"), 1794585516)
    eq(lib.iso_to_unix_time("nope"), nil)
  end)

  t("is_at_shell", function(eq)
    local login = { pid = 10, name = "login" }
    eq(lib.is_at_shell({ child = login, foreground = { pid = 11, name = "zsh" },
                      ancestors = { { pid = 10 } } }), true)
    eq(lib.is_at_shell({ child = login, foreground = { pid = 12, name = "alpha" },
                      ancestors = { { pid = 11 }, { pid = 10 } } }), false)
    eq(lib.is_at_shell({ child = { pid = 11 }, foreground = { pid = 11 } }), true)
    eq(lib.is_at_shell(nil), false)
  end)

  t("program_name", function(eq)
    eq(lib.program_name({ argv0 = "-zsh" }), "zsh")
    eq(lib.program_name({ argv0 = "/opt/homebrew/bin/alpha" }), "alpha")
    eq(lib.program_name({ name = "beta" }), "beta")
  end)

  t("parse_ps_line", function(eq)
    local age, argv = lib.parse_ps_line("   05:00 alpha resume " .. A)
    eq(age, 300)
    eq(#argv, 3)
    eq(argv[3], A)
    eq(lib.parse_ps_line("garbage"), nil)
  end)

  t("last_screen_line", function(eq)
    eq(lib.last_screen_line("a\n~/dev ❯ \n\n"), "~/dev ❯")
    eq(lib.last_screen_line(nil), nil)
  end)

  t("record_agent and note_agent_missing: the quit race", function(eq)
    local s = lib.new_state("i1")
    eq(lib.record_agent(s, "b1", { agent = "alpha", id = B }, 100), true)
    eq(lib.record_agent(s, "b1", { agent = "alpha", id = B }, 115), false)
    -- Quitting Rex closes the agents first: event sweeps never forget,
    eq(lib.note_agent_missing(s, "b1", false, false), false)
    eq(s.panes.b1 ~= nil, true)
    -- and one timed sweep isn't enough,
    eq(lib.note_agent_missing(s, "b1", false, true), false)
    eq(s.panes.b1 ~= nil, true)
    -- but a second one in a row is.
    eq(lib.note_agent_missing(s, "b1", false, true), true)
    eq(s.panes.b1, nil)
    -- A closed pane goes at the first timed sweep.
    lib.record_agent(s, "b2", { agent = "beta", id = A }, 100)
    eq(lib.note_agent_missing(s, "b2", true, true), true)
    -- Seeing the agent again resets the count.
    lib.record_agent(s, "b3", { agent = "beta", id = A }, 100)
    lib.note_agent_missing(s, "b3", false, true)
    lib.record_agent(s, "b3", { agent = "beta", id = A }, 130)
    eq(lib.note_agent_missing(s, "b3", false, true), false)
  end)

  t("sanitize_state", function(eq)
    eq(next(lib.sanitize_state(nil, agents).panes), nil)
    eq(next(lib.sanitize_state({ version = 99, panes = {} }, agents).panes), nil)
    local s = lib.sanitize_state({ version = 1, panes = {
      ok = { agent = "alpha", id = B }, bad = { agent = "alpha", id = "x; rm" },
      gone = { agent = "removed_agent", id = A } } }, agents)
    eq(s.panes.ok ~= nil, true)
    eq(s.panes.bad, nil)
    eq(s.panes.gone, nil)
  end)

  t("plan_restore: one pane per conversation", function(eq)
    local plan = lib.plan_restore({ panes = {
      b2 = { agent = "alpha", id = B }, b1 = { agent = "alpha", id = B }, b3 = { agent = "beta", id = A } } })
    eq(#plan, 2)
    eq(plan[1].block_id, "b1")
    eq(plan[2].block_id, "b3")
  end)

  t("next_pane_state: a steady prompt is typed once", function(eq)
    local S = lib.PANE_STATE
    local ready = { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = true, prompt_line = "~ ❯" }
    local pane, type_now = lib.next_pane_state({ state = S.WAITING }, ready)
    eq(pane.state, S.PROMPT_SEEN)
    eq(type_now, false)
    pane, type_now = lib.next_pane_state(pane, ready)       -- same line a second later
    eq(pane.state, S.TYPED)
    eq(type_now, true)
    local again
    pane, again = lib.next_pane_state(pane, ready)          -- final: stays typed, never again
    eq(pane.state, S.TYPED)
    eq(again, false)
  end)

  t("next_pane_state: a changing or missing prompt waits", function(eq)
    local S = lib.PANE_STATE
    local seen = { state = S.PROMPT_SEEN, prompt_line = "~ ❯" }
    local base = { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = true }
    base.prompt_line = "~ ❯ cl"                             -- someone is typing
    local pane, type_now = lib.next_pane_state(seen, base)
    eq(pane.state, S.PROMPT_SEEN)
    eq(pane.prompt_line, "~ ❯ cl")
    eq(type_now, false)
    eq(lib.next_pane_state(seen, { pane_exists = true, at_shell = true, shell = "zsh", editor_ready = false,
                                    prompt_line = "~ ❯" }).state, S.WAITING)  -- editor not reading keys
    eq(lib.next_pane_state(seen, { pane_exists = true, at_shell = false }).state, S.WAITING)
    eq(lib.next_pane_state(seen, { pane_exists = false }).state, S.WAITING)
  end)

  t("next_pane_state: final states", function(eq)
    local S = lib.PANE_STATE
    local waiting = { state = S.WAITING }
    eq(lib.next_pane_state(waiting, { pane_exists = true, agent_running = true }).state, S.ALREADY_RUNNING)
    eq(lib.next_pane_state(waiting, { typed_elsewhere = true, pane_exists = true }).state, S.TYPED_ELSEWHERE)
    local failed = lib.next_pane_state(waiting, { pane_exists = true, at_shell = true, shell = "sh" })
    eq(failed.state, S.FAILED)
    eq(type(failed.why), "string")
    eq(lib.is_final_pane_state(S.FAILED), true)
    eq(lib.is_final_pane_state(S.PROMPT_SEEN), false)
  end)

  t("should_run_restore: a finished restore never runs again", function(eq)
    local R = lib.RESTORE_STATE
    eq(lib.should_run_restore({ for_instance = "i2", state = R.PENDING }, "i2", 100, 200), true)
    eq(lib.should_run_restore({ for_instance = "i2" }, "i2", 100, 200), true)  -- written before `state` existed
    eq(lib.should_run_restore({ for_instance = "i2", state = R.FINISHED }, "i2", 100, 200), false)
    eq(lib.should_run_restore({ for_instance = "i1", state = R.PENDING }, "i2", 100, 200), false)
    eq(lib.should_run_restore({ for_instance = "i2", state = R.PENDING }, "i2", 300, 200), false)
    eq(lib.should_run_restore(nil, "i2", 100, 200), false)
  end)

  t("classify_finding", function(eq)
    local F = lib.FINDING
    local alpha = agents.by_name.alpha
    eq(lib.classify_finding(true, alpha, true), F.AGENT)
    eq(lib.classify_finding(true, alpha, false), F.AGENT_UNIDENTIFIED)
    eq(lib.classify_finding(true, nil, false), F.NO_AGENT)
    eq(lib.classify_finding(false, alpha, false), F.UNREADABLE)
  end)
end

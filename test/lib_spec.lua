-- Tests for lib.lua. Run with any Lua 5.1+:  lua test/run.lua
-- or inside Rex's own Lua:                    rex do test/run.lua

return function(t, lib)
  local A = "0193f2a4-5b6c-7d8e-9f01-23456789abcd"
  local B = "3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8"

  t("is_uuid", function(eq)
    eq(lib.is_uuid(A), true)
    eq(lib.is_uuid("newAppIdea"), false)
    eq(lib.is_uuid(A .. "; rm -rf ~"), false)
  end)

  t("sh_quote", function(eq)
    eq(lib.sh_quote("/a b"), "'/a b'")
    eq(lib.sh_quote("it's"), "'it'\\''s'")
    eq(lib.sh_quote("a\\b"), nil)
  end)

  t("resume_line", function(eq)
    eq(lib.resume_line({ agent = "claude", id = B, cwd = "/p q" }), "cd '/p q' && claude --resume " .. B)
    eq(lib.resume_line({ agent = "codex", id = A }), "codex resume " .. A)
    eq(lib.resume_line({ agent = "codex", id = "x" }), nil)
    eq(lib.resume_line({ agent = "vim", id = A }), nil)
    eq(lib.restore_input("ls"), "\21ls\r")
  end)

  t("parse_etime", function(eq)
    eq(lib.parse_etime("  01:05"), 65)
    eq(lib.parse_etime("02:01:05"), 7265)
    eq(lib.parse_etime("3-02:01:05"), 3 * 86400 + 7265)
    eq(lib.parse_etime("x"), nil)
  end)

  t("iso_to_epoch", function(eq)
    eq(lib.iso_to_epoch("1970-01-02T00:00:01Z"), 86401)
    eq(lib.iso_to_epoch("2026-11-13T15:58:36.494463Z"), 1794585516)
    eq(lib.iso_to_epoch("nope"), nil)
  end)

  t("at_shell", function(eq)
    local login = { pid = 10, name = "login" }
    eq(lib.at_shell({ child = login, foreground = { pid = 11, name = "zsh" },
                      ancestors = { { pid = 10 } } }), true)
    eq(lib.at_shell({ child = login, foreground = { pid = 12, name = "claude" },
                      ancestors = { { pid = 11 }, { pid = 10 } } }), false)
    eq(lib.at_shell({ child = { pid = 11 }, foreground = { pid = 11 } }), true)
    eq(lib.at_shell(nil), false)
  end)

  t("program", function(eq)
    eq(lib.program({ argv0 = "-zsh" }), "zsh")
    eq(lib.program({ argv0 = "/opt/homebrew/bin/codex" }), "codex")
    eq(lib.program({ name = "claude" }), "claude")
  end)

  t("parse_ps and codex_target", function(eq)
    local age, w = lib.parse_ps("   05:00 codex resume " .. A)
    eq(age, 300)
    eq(lib.codex_target(w).uuid, A)
    local _, w2 = lib.parse_ps("1:00 codex -m o3 --yolo resume newAppIdea")
    eq(lib.codex_target(w2).name, "newAppIdea")
    local _, w3 = lib.parse_ps("1:00 codex")
    eq(lib.codex_target(w3), nil)
    local _, w4 = lib.parse_ps("1:00 codex exec resume " .. A)
    eq(lib.codex_target(w4), nil)
    local _, w5 = lib.parse_ps("1:00 codex resume --last")
    eq(lib.codex_target(w5), nil)
  end)

  t("codex_title_name", function(eq)
    eq(lib.codex_title_name("newAppIdea | ~/dev"), "newAppIdea")
    eq(lib.codex_title_name("plain"), "plain")
    eq(lib.codex_title_name(""), nil)
  end)

  t("pick_codex_thread", function(eq)
    local rows = { { id = "n", name = "other", fresh = true }, { id = A, name = "app", fresh = true } }
    eq(lib.pick_codex_thread(rows, "app | ~/x", nil, true), A)     -- the title names it
    eq(lib.pick_codex_thread(rows, "zzz | ~/x", nil, false), "n")  -- alone: the newest
    local id, why = lib.pick_codex_thread(rows, "zzz | ~/x", nil, true)
    eq(id, nil)
    eq(type(why), "string")                                       -- shared: no guess
    local stale = { { id = A, name = "", fresh = false } }
    eq(lib.pick_codex_thread(stale, nil, { uuid = A }, false), A)  -- resumed, nothing typed yet
    eq(lib.pick_codex_thread({}, "app", nil, false), nil)
  end)

  t("codex_id_by_name", function(eq)
    local text = '{"id":"' .. B .. '","thread_name":"app"}\n{"id":"' .. A .. '","thread_name":"app"}\n'
    local function decode(line)
      local id, name = line:match('"id":"([^"]+)","thread_name":"([^"]+)"')
      return { id = id, thread_name = name }
    end
    eq(lib.codex_id_by_name(text, "app", decode), A)  -- the newest entry wins
    eq(lib.codex_id_by_name(text, "none", decode), nil)
  end)

  t("cursor_line", function(eq)
    eq(lib.cursor_line("a\n~/dev ❯ \n\n"), "~/dev ❯")
    eq(lib.cursor_line(nil), nil)
  end)

  t("observe and miss: the quit race", function(eq)
    local s = lib.new_state("i1")
    eq(lib.observe(s, "b1", { agent = "claude", id = B }, 100), true)
    eq(lib.observe(s, "b1", { agent = "claude", id = B }, 115), false)
    -- Quitting Rex closes the agents first: event sweeps never forget,
    eq(lib.miss(s, "b1", false, false), false)
    eq(s.panes.b1 ~= nil, true)
    -- and one timed sweep isn't enough,
    eq(lib.miss(s, "b1", false, true), false)
    eq(s.panes.b1 ~= nil, true)
    -- but a second one in a row is.
    eq(lib.miss(s, "b1", false, true), true)
    eq(s.panes.b1, nil)
    -- A closed pane goes at the first timed sweep.
    lib.observe(s, "b2", { agent = "codex", id = A }, 100)
    eq(lib.miss(s, "b2", true, true), true)
    -- Seeing the agent again resets the count.
    lib.observe(s, "b3", { agent = "codex", id = A }, 100)
    lib.miss(s, "b3", false, true)
    lib.observe(s, "b3", { agent = "codex", id = A }, 130)
    eq(lib.miss(s, "b3", false, true), false)
  end)

  t("clean_state", function(eq)
    eq(next(lib.clean_state(nil).panes), nil)
    eq(next(lib.clean_state({ version = 99, panes = {} }).panes), nil)
    local s = lib.clean_state({ version = 1, panes = {
      ok = { agent = "claude", id = B }, bad = { agent = "claude", id = "x; rm" } } })
    eq(s.panes.ok ~= nil, true)
    eq(s.panes.bad, nil)
  end)

  t("plan_restore: one pane per conversation", function(eq)
    local plan = lib.plan_restore({ panes = {
      b2 = { agent = "claude", id = B }, b1 = { agent = "claude", id = B }, b3 = { agent = "codex", id = A } } })
    eq(#plan, 2)
    eq(plan[1].block_id, "b1")
    eq(plan[2].block_id, "b3")
  end)
end

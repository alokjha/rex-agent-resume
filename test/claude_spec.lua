-- Tests for agents/claude, through the Agent protocol only, with a fake host.

return function(t, core, agents)
  local claude, fake_host = agents.by_name.claude, core.fakes.host
  local A, B = core.fakes.A, core.fakes.B
  local pane = { block_id = "block:1", session = "s" }

  t("claude: detect reads the session file", function(eq)
    local found = claude.detect(pane, { pid = 42, cwd = "/x" }, {}, fake_host({
      files = { ["/home/me/.claude/sessions/42.json"] = { pid = 42, sessionId = B, cwd = "/proj" } },
      commands = { ["/bin/sh"] = { ok = true } } }))
    eq(found and found.id, B)
    eq(found and found.cwd, "/proj")
    -- No transcript yet: nothing to resume.
    eq(claude.detect(pane, { pid = 43 }, {}, fake_host({
      files = { ["/home/me/.claude/sessions/43.json"] = { pid = 43, sessionId = A } },
      commands = { ["/bin/sh"] = { ok = false } } })), nil)
    -- A session file left by another process.
    eq(claude.detect(pane, { pid = 44 }, {}, fake_host({
      files = { ["/home/me/.claude/sessions/44.json"] = { pid = 9, sessionId = A } },
      commands = { ["/bin/sh"] = { ok = true } } })), nil)
  end)
end

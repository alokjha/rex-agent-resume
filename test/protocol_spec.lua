-- Tests for core/agent_protocol.lua: which agents the registry takes.

return function(t, core)
  local protocol, agent = core.agent_protocol, core.fakes.agent

  t("new_registry: a bad agent is skipped, the others kept", function(eq)
    local registry, skipped = protocol.new_registry({ agent("a", { "a", "a2" }), agent("b") })
    eq(registry.by_program.a2.name, "a")
    eq(registry.by_name.b.name, "b")
    eq(#registry.list, 2)
    eq(#skipped, 0)
    local function kept_and_skipped(list)
      local kept, why = protocol.new_registry(list)
      return #kept.list, #why
    end
    local missing = agent("a")
    missing.detect = nil
    local kept, n = kept_and_skipped({ missing, agent("b") })      -- doesn't implement the protocol
    eq(kept, 1) eq(n, 1)
    local misspelled = agent("a")
    misspelled.resume_comand = function() end
    kept, n = kept_and_skipped({ misspelled, agent("b") })          -- a member the protocol doesn't have
    eq(kept, 1) eq(n, 1)
    kept, n = kept_and_skipped({ agent("a b"), agent("b") })        -- a name that isn't a word
    eq(kept, 1) eq(n, 1)
    kept, n = kept_and_skipped({ agent("a", {}), agent("b") })      -- no programs
    eq(kept, 1) eq(n, 1)
    kept, n = kept_and_skipped({ agent("a"), agent("a") })          -- the same name twice
    eq(kept, 1) eq(n, 1)
    local clash, why = protocol.new_registry({ agent("a", { "x" }), agent("b", { "x", "y" }) })
    eq(#clash.list, 1)                   -- one program, two agents: the first keeps it
    eq(clash.by_program.y, nil)          -- and the skipped one claims nothing
    eq(why[1], "agent b: agent a already claims x")
  end)
end

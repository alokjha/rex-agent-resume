-- Tests for core/recording.lua: what is recorded, and when it is forgotten.

return function(t, core)
  local recording, fakes = core.recording, core.fakes
  local STOPPED, CLOSED = recording.MISSING.AGENT_STOPPED, recording.MISSING.PANE_CLOSED
  local ON_EVENT, TIMED = recording.SWEEP.ON_EVENT, recording.SWEEP.TIMED
  local A, B = fakes.A, fakes.B
  local agents = fakes.registry()

  t("record_agent and note_agent_missing: the quit race", function(eq)
    local s = recording.new_state("i1")
    eq(recording.record_agent(s, "b1", { agent = "alpha", id = B }, 100), true)
    eq(recording.record_agent(s, "b1", { agent = "alpha", id = B }, 115), false)
    -- Stopping Rex closes the agents first: event sweeps never forget,
    eq(recording.note_agent_missing(s, "b1", STOPPED, ON_EVENT), false)
    eq(s.panes.b1 ~= nil, true)
    -- and one timed sweep isn't enough,
    eq(recording.note_agent_missing(s, "b1", STOPPED, TIMED), false)
    eq(s.panes.b1 ~= nil, true)
    -- but a second one in a row is.
    eq(recording.note_agent_missing(s, "b1", STOPPED, TIMED), true)
    eq(s.panes.b1, nil)
    -- A closed pane goes at the first timed sweep.
    recording.record_agent(s, "b2", { agent = "beta", id = A }, 100)
    eq(recording.note_agent_missing(s, "b2", CLOSED, TIMED), true)
    -- Seeing the agent again resets the count.
    recording.record_agent(s, "b3", { agent = "beta", id = A }, 100)
    recording.note_agent_missing(s, "b3", STOPPED, TIMED)
    recording.record_agent(s, "b3", { agent = "beta", id = A }, 130)
    eq(recording.note_agent_missing(s, "b3", STOPPED, TIMED), false)
  end)

  t("start: a new server restores what the last one ran, once", function(eq)
    local saved = { version = 1, instance_id = "i1", panes = { b1 = { agent = "alpha", id = B } } }
    local state, to_restore, save_now = recording.start(saved, "i2", nil, 1000)   -- the first look at server i2
    eq(next(state.panes), nil)
    eq(state.instance_id, "i2")
    eq(to_restore.from_instance, "i1")
    eq(to_restore.panes.b1.id, B)
    eq(to_restore.created_at, 1000)
    eq(save_now, true)
    local _, again = recording.start(saved, "i2", { for_instance = "i2" }, 1000)  -- a watcher started with it wrote it
    eq(again, nil)
    local same, none = recording.start(saved, "i1", nil, 1000)                    -- the same server: carry on
    eq(same, saved)
    eq(none, nil)
  end)

  t("start: a restore cut short by another restart is restored again", function(eq)
    -- Server i2 was restoring i1's b1 when it stopped; it had recorded only b2.
    local cut_short = { for_instance = "i2", from_instance = "i1", created_at = 1000,
      state = "pending", panes = { b1 = { agent = "alpha", id = B } }, typed = { b1 = 1005 } }
    local saved = { version = 1, instance_id = "i2", swept_at = 1015, panes = { b2 = { agent = "beta", id = A } } }
    local _, to_restore = recording.start(saved, "i3", cut_short, 5000)   -- however long Rex stayed down
    eq(to_restore.panes.b1.id, B)
    eq(to_restore.panes.b2.id, A)
    eq(next(to_restore.typed), nil)
    saved.swept_at = nil                                                 -- stopped before its first timed sweep
    eq(select(2, recording.start(saved, "i3", cut_short, 5000)).panes.b1.id, B)
    -- Not when server i2 ran on past the window, when it finished, or when it was for another server.
    saved.swept_at = 1000 + core.restore.WINDOW_SECONDS + 15
    eq(select(2, recording.start(saved, "i3", cut_short, 5000)).panes.b1, nil)
    saved.swept_at = 1015
    cut_short.state = "finished"
    eq(select(2, recording.start(saved, "i3", cut_short, 1015)).panes.b1, nil)
    cut_short.state, cut_short.for_instance = "pending", "i9"
    eq(select(2, recording.start(saved, "i3", cut_short, 1015)).panes.b1, nil)
  end)

  t("sanitize_state", function(eq)
    eq(next(recording.sanitize_state(nil, agents).panes), nil)
    eq(next(recording.sanitize_state({ version = 99, panes = {} }, agents).panes), nil)
    local s = recording.sanitize_state({ version = 1, panes = {
      ok = { agent = "alpha", id = B }, bad = { agent = "alpha", id = "x; rm" },
      unloaded = { agent = "gamma", id = "any-id" }, junk = { agent = 5, id = A } } }, agents)
    eq(s.panes.ok ~= nil, true)
    eq(s.panes.bad, nil)
    eq(s.panes.unloaded ~= nil, true)   -- its agent isn't loaded: kept for when it is
    eq(s.panes.junk, nil)
  end)
end

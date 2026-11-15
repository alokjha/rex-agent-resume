-- Tests for agents/codex, through the Agent protocol only, with a fake host.

return function(t, core, agents)
  local codex, fake_host = agents.by_name.codex, core.fakes.host
  local A, B = core.fakes.A, core.fakes.B
  local pane = { block_id = "block:1", session = "s" }

  -- A Codex host: the TUI's command line (10 seconds old), the thread rows
  -- the database returns (nil: it can't be read), session_index.jsonl and the title.
  local function codex_host(command_line, rows, index_lines, title)
    local json, rows_text = {}, nil
    if rows then
      rows_text = "rows" .. #rows
      json[rows_text] = rows
    end
    local index_text = ""
    for _, entry in ipairs(index_lines or {}) do
      local line = "index:" .. entry.thread_name .. ":" .. entry.id
      json[line] = entry
      index_text = index_text .. line .. "\n"
    end
    return fake_host({
      json = json, title = title,
      files = { ["/home/me/.codex/session_index.jsonl"] = index_text,
                -- a -wal file: an unreadable database isn't retried as immutable
                ["/home/me/.codex/state_5.sqlite-wal"] = "" },
      commands = {
        ps = { ok = true, stdout = "00:10 " .. command_line .. "\n" },
        ["/bin/sh"] = { ok = true, stdout = "/home/me/.codex/state_5.sqlite\n" },
        sqlite3 = rows and { ok = true, stdout = rows_text } or { ok = false, stderr = "locked" },
      },
    })
  end
  local function in_folder(folder) return { pid = 7, cwd = folder } end
  local alone = { { foreground = { cwd = "/q" } } }
  local shared = { { foreground = { cwd = "/p" } }, { foreground = { cwd = "/p" } } }
  local NEW, OLD = 999000, 100 -- updated_ms: written since the TUI started, or before

  t("codex: detect from the database", function(eq)
    local rows = { { id = A, name = "app", updated_ms = NEW } }
    -- Alone in its folder: the newest thread is it.
    local found = codex.detect(pane, in_folder("/q"), alone, codex_host("codex", rows, nil, "zzz | /q"))
    eq(found and found.id, A)
    eq(found and found.cwd, "/q")
    -- Sharing the folder: only a title naming the thread tells.
    local id, why = codex.detect(pane, in_folder("/p"), shared, codex_host("codex", rows, nil, "zzz | /p"))
    eq(id, nil)
    eq(type(why), "string")
    found = codex.detect(pane, in_folder("/p"), shared, codex_host("codex", rows, nil, "app | /p"))
    eq(found and found.id, A)
  end)

  t("codex: detect a resumed thread", function(eq)
    -- `codex resume A`, nothing written since: A, though it was written before.
    local found = codex.detect(pane, in_folder("/q"), alone,
      codex_host("codex resume " .. A, { { id = A, name = "", updated_ms = OLD } }))
    eq(found and found.id, A)
    -- A newer thread written since (a /new): that one.
    found = codex.detect(pane, in_folder("/q"), alone, codex_host("codex resume " .. A,
      { { id = B, name = "", updated_ms = NEW }, { id = A, name = "", updated_ms = OLD } }))
    eq(found and found.id, B)
  end)

  t("codex: detect without the database", function(eq)
    -- The command line names the thread.
    local found = codex.detect(pane, in_folder("/q"), alone, codex_host("codex -m o3 resume " .. A))
    eq(found and found.id, A)
    -- The title's name, in session_index.jsonl: the newest entry wins.
    local index = { { id = B, thread_name = "app" }, { id = A, thread_name = "app" } }
    found = codex.detect(pane, in_folder("/q"), alone, codex_host("codex", nil, index, "app | /q"))
    eq(found and found.id, A)
    -- `codex resume <name>`, looked up the same way.
    found = codex.detect(pane, in_folder("/q"), alone, codex_host("codex resume app", nil, index, ""))
    eq(found and found.id, A)
    -- Nothing names it.
    eq(codex.detect(pane, in_folder("/q"), alone, codex_host("codex resume --last", nil, index, "")), nil)
    -- `codex exec resume A` isn't the TUI resuming A.
    eq(codex.detect(pane, in_folder("/q"), alone, codex_host("codex exec resume " .. A, nil, nil, "")), nil)
  end)
end

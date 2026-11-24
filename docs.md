# rex-agent-resume: how it works

For installing and using it, see the [README](README.md).

- [How it works](#how-it-works)
- [What install.sh does](#what-installsh-does)
- [Files](#files)
- [Troubleshooting](#troubleshooting)
- [Limits](#limits)
- [History](#history)
- [Develop](#develop)

## How it works

`rex-agent-resume.lua`, loaded by `init.lua`, starts `watcher.lua` in the background each time Rex loads its config. Only one watcher runs: the newest replaces an older one, and watchers started at the same moment agree on one before any of them types.

### Recording which conversation runs where

The watcher looks at every pane when a pane's program changes or a pane closes, and every 15 seconds, which also catches a conversation switched inside the agent (Claude's `/clear` and `/resume`). Rex keeps a pane's ID across restarts, so the record is keyed by pane.

| Agent | Where the conversation ID comes from |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json`, which Claude Code writes for each running process. A conversation is recorded once its transcript exists (before its first message there's nothing to resume). |
| Codex | Codex doesn't record which process runs which conversation, so it's worked out: the conversations ("threads") in Codex's state database, `~/.codex/state_N.sqlite`, that are in the pane's folder and were written since that Codex started. If two Codex panes share a folder, the conversation name Codex shows in the tab title decides; if it can't, the pane isn't guessed (see [Limits](#limits)). If the database can't be read, it falls back to `codex resume <id>` on the command line, then to the title's name in `~/.codex/session_index.jsonl`. |

When the Rex server stops, it closes the agents a few seconds before it exits. So that doesn't wipe the record, an agent is forgotten only after two 15-second checks in a row don't find it (or at once if its pane is closed).

### Resuming after a restart

When the watcher first sees a new Rex server, it saves what the previous one ran in `restore.json` and steps each pane through these states, once a second:

```
waiting ──prompt drawn──▶ prompt_seen ──same prompt a second later──▶ typed
   ▲                           │
   └────── anything else ──────┘
```

A pane counts as ready when its foreground program is the shell Rex started (zsh, bash or fish), the shell is reading keys, and its prompt line hasn't changed for a second, so nothing is being typed. It then gets Ctrl-U (clearing the line), the resume command and Enter.

- A pane is marked before it's typed into, so it's never typed into twice, even if the watcher is replaced mid-restore.
- A conversation recorded in two panes is resumed in the first only.
- A pane already running its agent is left alone.
- After 120 seconds the restore is finished: panes that weren't ready are left as they are, and a macOS notification lists them. A finished restore never runs again, even after a config reload.
- If Rex stops again before a restore finishes (within its 120 seconds), the next server restores that restore's panes too, as well as what it recorded itself.

## What install.sh does

It:

1. backs up your `init.lua` (`$REX_CONFIG`, else `$XDG_CONFIG_HOME/rex/init.lua`, else `~/.config/rex/init.lua`) next to it, as `init.lua.bak-rex-agent-resume-<date>-<pid>`;
2. adds a block marked `-- >>> rex-agent-resume >>>` that loads the tool and binds **Resume Agents** to `shift+cmd+r`. A clone beside `init.lua` is loaded with `require("rex-agent-resume")`, as when [installing by hand](README.md#install); one elsewhere by its path. Run it again and it rewrites its own block, leaving the rest of the file alone;
3. checks the result with `rex config check`, and puts the old file back if the check fails;
4. reloads Rex's config, which starts the watcher.

Keep the clone where you put it: `init.lua` loads the tool from there.

`--uninstall` takes the block out of `init.lua` (with a backup) and stops the watcher. Removing a by-hand install, stop the watcher yourself after deleting your lines: `kill $(cat ~/.local/state/rex-agent-resume/watcher.pid)`. Either way, the records in `~/.local/state/rex-agent-resume/` are left for you to delete.

In a dotfiles setup (chezmoi, Nix home-manager, a symlinked `~/.config/rex`), manage the clone and its `require` or `dofile` line like the rest of your config.

Rex has no plugin manager, which is why the tool is loaded by a line in `init.lua`. Rex's `require` finds Lua files beside `init.lua`, so `require("rex-agent-resume")` loads the repository's own `init.lua`, which loads the tool.

## Files

In `~/.local/state/rex-agent-resume/` (or `$XDG_STATE_HOME/rex-agent-resume/`), readable only by you:

| File | Holds |
| --- | --- |
| `state.json` | For each pane with an agent: the agent, the conversation ID, the folder and the Rex session's name. |
| `restore.json` | What the previous server ran, which panes were typed into, whether the restore is `pending` or `finished`, and why any pane couldn't be resumed. |
| `watcher.log` | What the watcher did, rotated at 1 MB. |
| `watcher.pid` | The running watcher's process ID. |

It reads Claude Code's per-process session files, Codex's thread IDs, names and folders, and the panes' titles and last screen line. It checks that a Claude transcript exists without reading it, and reads no prompts and nothing from the agents' environment. Nothing leaves your machine.

## Troubleshooting

Start with `watcher.log`. Each pane resumed has a `resumed …` line; anything that went wrong has a `warn:` line.

| What you see | Why, and what to do |
| --- | --- |
| A pane came back as a plain shell | It probably wasn't at a prompt within 120 seconds (a slow shell start, or something else running). Press **Resume Agents**. |
| Codex stopped at "Update available" or a folder-trust question | Those are Codex's own prompts. Answer them; the conversation resumes after. |
| `command not found: claude` (or `codex`) | The agent isn't on the `PATH` of a new shell. Fix your shell's `PATH`. |
| A Codex pane is missing from `mode=status` | Another Codex runs in the same folder and their names don't tell them apart. Give the conversations distinct names with Codex's `/rename`. |
| Nothing is recorded at all | Check that `init.lua` loads the tool (the install script's block, or your `require` or `dofile` line), that `rex config check` passes, and that a watcher runs: `ps -p $(cat ~/.local/state/rex-agent-resume/watcher.pid)`. |

## Limits

- Developed and tested on macOS 27 with Rex 0.1.0 previews (up to preview.19), Claude Code 2.1 and Codex 0.167 to 0.169. Linux should work, except the failure notifications, which use macOS's `osascript`; it hasn't been tested there.
- Without `sqlite3`, Codex conversations are found from the command line and the tab title only.
- Agents resume with their default options: flags such as `--model` or a permission mode aren't carried over.
- Only Claude Code and Codex for now (others can be added: see [Adding an agent](#adding-an-agent)), and only panes running zsh, bash or fish.
- A pane closed while Rex was down isn't brought back.
- A shell left in vi command mode (not insert mode) may not take the typed line correctly.
- A folder whose path holds a backslash isn't restored, because fish reads single-quoted backslashes differently from zsh and bash.
- Two Codex panes in the same folder are told apart only by their conversation names. If both are unnamed or share a name, the pane keeps the last ID it was sure of, or isn't recorded. A Codex `SessionStart` hook can't fix this: Codex's shared background service runs hooks with the environment of whichever pane started it, so a hook can't tell which pane it's for.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are read from the Rex server's environment, not from each agent's.
- Codex's database and index are Codex's own formats and may change between versions. Each has a fallback, and the log says when one is used.
- `rex config check` runs `init.lua`, so it starts a watcher too. That one replaces the running watcher, which is harmless.

## History

This grew out of a resume script written for the author's own Rex setup and tested over several real restarts. Its approach is still the core of this one:

- the conversation each pane runs, from Claude Code's per-process session file, and for Codex from `codex resume <id>` or the conversation name in the pane's title, looked up in `session_index.jsonl` (which covers plain `codex` and `codex resume <name>`);
- a record keyed by Rex's pane IDs, which survive restarts;
- resuming once per new server, only into panes back at a shell prompt, never twice into one pane;
- one watcher at a time, the newest replacing an older or stuck one, and the Resume Agents action.

## Develop

```
init.lua                  lets require("rex-agent-resume") load the tool (not a Rex config)
rex-agent-resume.lua      what your init.lua loads: starts the watcher, adds Resume Agents
watcher.lua               the entry point: its modes, one watcher at a time, Rex's events
install.sh                adds the tool to init.lua, or takes it out

core/                     knows no agent by name
  agent_protocol.lua      the Agent and Host protocols, and the registry of agents
  recording.lua           state.json: what a sweep found, recording, forgetting
  restore.lua             when and what is typed back into a pane: the restore states
  sweep.lua               one look at every pane, asking each pane's agent
  resume.lua              typing the resume commands after a restart
  rex_server.lua          what the watcher asks the Rex server
  host.lua                what the watcher lends every agent (the Host protocol)
  singleton.lua           one watcher at a time
  status.lua              the mode=status printout
  files.lua               reading and writing the watcher's files
  shell.lua               small helpers about shells and processes

agents/
  init.lua                the list of agents to load
  claude/claude.lua       Claude Code
  codex/codex.lua         Codex, with its helpers beside it:
  codex/command_line.lua    what a Codex process's command line says
  codex/threads.lua         choosing which thread a Codex TUI is on
  codex/database.lua        reading Codex's thread database
```

`recording.lua` and `restore.lua` hold the rules and don't talk to Rex, so the tests cover them.

### Adding an agent

`core/agent_protocol.lua` declares the `Agent` protocol: the five members an agent must have, with their types and signatures. An agent is a folder in `agents/` whose `<name>/<name>.lua` returns a table with exactly those. It is loaded with `core/shell.lua` and its own folder:

```lua
local shell, folder = ...

local myagent = {
  name = "myagent",          -- recorded in state.json
  programs = { "myagent" },  -- foreground program names that mean it runs
}

-- The ID is typed into a shell: accept only safe ones.
function myagent.is_valid_id(id) return shell.is_uuid(id) end

function myagent.resume_command(id) return "myagent --resume " .. id end

-- Which conversation runs in this pane: { id = ..., cwd = ... }, or nil and why.
-- `peers` is every pane this agent runs in now, for an agent that needs to
-- compare (Codex checks whether another Codex shares the folder).
function myagent.detect(pane, foreground, peers, host)
  local session = host.read_json(host.home .. "/.myagent/sessions/" .. foreground.pid .. ".json")
  return session and { id = session.id, cwd = foreground.cwd }
end

return myagent
```

Then add its name to `AGENTS` in `agents/init.lua`.

- When the watcher starts, the registry checks each agent against the protocol: every member there and of its type, nothing else (so a misspelling shows), and no program claimed by two agents. An agent that fails is skipped with a warning in `watcher.log`, and the others keep working. Records of a skipped agent are kept, so once its file is fixed, **Resume Agents** can still bring them back.
- The core calls only the five members. Anything else an agent needs stays its own: `local` to its file, or in helper files in its folder, loaded with `loadfile(folder .. "/helper.lua")` (as Codex does). The watcher finds the agent's panes by program name, records what `detect` returns (if its own `is_valid_id` accepts the ID), and types `cd <folder> && <resume_command>` after a restart. Everything else (when to forget, the restore states, typing once per pane) is shared.
- An agent uses only `host`, the `Host` protocol (files, commands, the pane's terminal), never `rex` itself. Its tests call its five functions with a fake host: see `test/codex_spec.lua`. The core's tests use made-up agents (`test/fakes.lua`).

### Tests

Run the tests with Lua 5.1 (the version Rex embeds), or with Rex itself:

```sh
lua5.1 test/run.lua
rex do test/run.lua
sh test/install_test.sh    # install.sh, against scratch configs and a fake rex
```

To try a restore without restarting Rex, make a scratch pane, and a scratch state folder whose `state.json` says that pane ran Claude Code under another server. Then start a watcher on it with `restore_test=1`, which counts the 120 seconds from now instead of from the server's start. Use a made-up conversation ID, so no real conversation is opened twice (Claude Code then says it can't find it):

```sh
rex new rar-test --json             # prints the new pane's block ID, "block:…"
mkdir -p /tmp/rar-test
cat > /tmp/rar-test/state.json <<'EOF'
{"version": 1, "instance_id": "some-earlier-server",
 "panes": {"<the block ID>":
   {"agent": "claude", "id": "<any UUID, from uuidgen>", "cwd": "/tmp", "session": "rar-test"}}}
EOF
rex do --all watcher.lua state=/tmp/rar-test restore_test=1 notify=0
```

The watcher should print `resumed claude … in rar-test`, and the pane should run `claude --resume`. Stop the watcher with Ctrl-C and close the pane with `rex kill rar-test`.

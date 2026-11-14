# rex-agent-resume

Brings your Claude Code and Codex conversations back into their [Rex](https://www.superlogical.com/rex) panes after the Rex server restarts: when you quit and reopen Rex, reboot, or Rex updates.

Rex already brings back your sessions, tabs, splits and each pane's folder after a restart, but the programs that ran in the panes are gone: you get plain shells. This tool remembers which conversation ran in which pane, and once Rex is back, types the command that resumes it into that pane:

```
before the restart   a pane in ~/code/app was running Claude Code, conversation 3f2a1b4c-…
after the restart    it types:  cd '/Users/you/code/app' && claude --resume 3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8
```

It works however the agent was started: `claude`, `claude --resume …`, plain `codex`, `codex resume <id>` or `codex resume <name>`.

## Requirements

- Rex, with its server restoring your sessions (the default).
- Claude Code and/or Codex, on the `PATH` of a new shell.
- `sqlite3` on `PATH` for the most reliable Codex results (macOS includes it). Without it, Codex conversations are found from the command line and the tab title only.

Developed and tested on macOS 27 with Rex 0.1.0 previews (up to preview.18), Claude Code 2.1 and Codex 0.167 to 0.169. Linux should work, except the failure notifications, which use macOS's `osascript`; it hasn't been tested there.

## Install

Rex has no plugin manager: a tool like this is loaded by a line in your `init.lua`. There are two ways to add it.

### With the install script

```sh
git clone https://github.com/alokjha/rex-agent-resume ~/.config/rex/rex-agent-resume
~/.config/rex/rex-agent-resume/install.sh --key shift+cmd+r
```

`--key` is optional: it binds a key to **Resume Agents** (see [Resume by hand](#resume-by-hand)). Without it, the action is still in Rex's command palette. A key already bound to something else is refused.

`install.sh`:

1. backs up your `init.lua` (`$REX_CONFIG`, else `$XDG_CONFIG_HOME/rex/init.lua`, else `~/.config/rex/init.lua`) next to it, as `init.lua.bak-rex-agent-resume-<date>-<pid>`;
2. adds a block marked `-- >>> rex-agent-resume >>>` that loads the tool, plus the key binding if you passed one. A clone beside `init.lua` is loaded with `require("rex-agent-resume")`, as when [installing by hand](#by-hand); one elsewhere by its path. Run it again to change or drop the key: it rewrites its own block and leaves the rest of the file alone;
3. checks the result with `rex config check`, and puts the old file back if the check fails;
4. names any other background Rex scripts that are running, since another tool that resumes agents would run as one;
5. reloads Rex's config, which starts the watcher, and reports how many agent panes the watcher has recorded.

Keep the clone where you put it: `init.lua` loads the tool from there.

### By hand

Clone the repository into Rex's config folder, beside your `init.lua`:

```sh
git clone https://github.com/alokjha/rex-agent-resume ~/.config/rex/rex-agent-resume
```

Add these lines to `~/.config/rex/init.lua` (the key is optional):

```lua
require("rex-agent-resume")
rex.bind("shift+cmd+r", "resume_agents")
```

Then run `rex config check` and `rex config reload`. Rex's `require` finds Lua files beside `init.lua`, so this loads the repository's own `init.lua`, which loads the tool.

If you keep the clone somewhere else, load it by its path instead:

```lua
dofile("/path/to/rex-agent-resume/rex-agent-resume.lua")
```

This also suits a dotfiles setup (chezmoi, Nix home-manager, a symlinked `~/.config/rex`): manage the clone and one of these lines like the rest of your config.

**Run only one tool that resumes agents after a restart.** Two would type the resume command twice into each pane. If you already use one, turn off its agent restore or remove it before installing this.

### Check that it works

```sh
cd ~/.config/rex/rex-agent-resume
rex do --all watcher.lua mode=status
```

lists every pane with an agent it has recorded, for example:

```
server 5963dd25-…, last timed sweep 18:03:53
  api                  claude 3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8  /Users/you/code/api
  web                  codex  0193f2a4-5b6c-7d8e-9f01-23456789abcd  /Users/you/code/web
```

Then quit Rex completely and open it again. Within a few seconds of each pane's prompt appearing, its agent starts again.

### Update and remove

- **Update:** `~/.config/rex/rex-agent-resume/install.sh --update` pulls the latest version and reloads Rex's config. Installed by hand: `git -C ~/.config/rex/rex-agent-resume pull`, then `rex config reload`.
- **Remove:** `~/.config/rex/rex-agent-resume/install.sh --uninstall`. It takes the block out of `init.lua` (with a backup) and stops the watcher. Installed by hand: delete the lines you added, run `rex config reload`, and stop the watcher with `kill $(cat ~/.local/state/rex-agent-resume/watcher.pid)`. Its records in `~/.local/state/rex-agent-resume/` are left for you to delete.

## Resume by hand

**Resume Agents** (the key you chose, the command palette, or `rex do --all ~/.config/rex/rex-agent-resume/watcher.lua mode=resume`) types the conversations from the last restart into any of their panes that is at a shell prompt and isn't running its agent, then prints what it did:

```
resumed 1, already running 8, not resumed 0
```

Use it when a pane wasn't ready within the 120 seconds after a restart. It only knows the conversations that ran when Rex last restarted, so it can't bring back one started since.

## How it works

`rex-agent-resume.lua`, loaded by `init.lua`, starts `watcher.lua` in the background each time Rex loads its config. Only one watcher runs: the newest replaces an older one, and watchers started at the same moment agree on one before any of them types.

### Recording which conversation runs where

The watcher looks at every pane when a pane's program changes or a pane closes, and every 15 seconds, which also catches a conversation switched inside the agent (Claude's `/clear` and `/resume`). Rex keeps a pane's ID across restarts, so the record is keyed by pane.

| Agent | Where the conversation ID comes from |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json`, which Claude Code writes for each running process. A conversation is recorded once its transcript exists (before its first message there's nothing to resume). |
| Codex | Codex doesn't record which process runs which conversation, so it's worked out: the conversations ("threads") in Codex's state database, `~/.codex/state_N.sqlite`, that are in the pane's folder and were written since that Codex started. If two Codex panes share a folder, the conversation name Codex shows in the tab title decides; if it can't, the pane isn't guessed (see [Limits](#limits)). If the database can't be read, it falls back to `codex resume <id>` on the command line, then to the title's name in `~/.codex/session_index.jsonl`. |

When you quit Rex, it closes the agents a few seconds before its server stops. So that doesn't wipe the record, an agent is forgotten only after two 15-second checks in a row don't find it (or at once if its pane is closed).

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

- Agents resume with their default options: flags such as `--model` or a permission mode aren't carried over.
- Only Claude Code and Codex for now (others can be added: see [Adding an agent](#adding-an-agent)), and only panes running zsh, bash or fish.
- A pane closed while Rex was down isn't brought back.
- A shell left in vi command mode (not insert mode) may not take the typed line correctly.
- A folder whose path holds a backslash isn't restored, because fish reads single-quoted backslashes differently from zsh and bash.
- Two Codex panes in the same folder are told apart only by their conversation names. If both are unnamed or share a name, the pane keeps the last ID it was sure of, or isn't recorded. A Codex `SessionStart` hook can't fix this: Codex's shared background service runs hooks with the environment of whichever pane started it, so a hook can't tell which pane it's for.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are read from the Rex server's environment, not from each agent's.
- Codex's database and index are Codex's own formats and may change between versions. Each has a fallback, and the log says when one is used.
- `rex config check` runs `init.lua`, so it starts a watcher too. That one replaces the running watcher, which is harmless.

## Develop

| File | Does |
| --- | --- |
| `init.lua` | Not a Rex config: lets `require("rex-agent-resume")` load the tool when the repository sits beside your `init.lua`. |
| `rex-agent-resume.lua` | Loaded by your `init.lua`: starts the watcher and adds the Resume Agents action. |
| `watcher.lua` | The watcher, plus `mode=resume` and `mode=status`. Everything that talks to Rex. It knows no agent by name: it asks the registry. |
| `lib.lua` | The logic that doesn't need Rex or any agent: the registry, parsing, when to forget, the restore states. The tests cover it. |
| `agents/init.lua` | The registry: the list of agents, and what an agent file must provide. |
| `agents/claude.lua`, `agents/codex.lua` | One file per agent: how to tell which conversation runs in a pane, and the command that resumes it. |
| `install.sh` | Adds the tool to `init.lua`, or `--uninstall` takes it out. |

### Adding an agent

Each agent is one file in `agents/`, loaded with `lib.lua` as its argument. It returns a table:

```lua
local lib = ...

return {
  name = "myagent",              -- recorded in state.json
  programs = { "myagent" },      -- foreground program names that mean it runs
  is_valid_id = lib.is_uuid,     -- the ID is typed into a shell: accept only safe ones
  resume_command = function(id) return "myagent --resume " .. id end,
  -- Which conversation runs in this pane: { id = ..., cwd = ... }, or nil and why.
  -- `peers` is every pane this agent runs in now, for an agent that needs to
  -- compare (Codex checks whether another Codex shares the folder).
  detect = function(pane, foreground, peers, host)
    local session = host.read_json(host.home .. "/.myagent/sessions/" .. foreground.pid .. ".json")
    return session and { id = session.id, cwd = foreground.cwd }
  end,
}
```

All five fields are required, and the registry refuses any other, so a misspelled one shows when the watcher starts. The core calls only these five; anything else the agent needs stays `local` to its file. Then add its name to `AGENTS` in `agents/init.lua`. The watcher finds the agent's panes by program name, records what `detect` returns, and types `cd <folder> && <resume_command>` after a restart. Everything else (when to forget, the restore states, typing once per pane) is shared.

An agent uses only `host` (files, commands, the pane's terminal; listed in `agents/init.lua`), never `rex` itself, so its tests can call its five functions with a fake host: see `test/agents_spec.lua`. The core's own tests, in `test/lib_spec.lua`, use made-up agents. The registry refuses a malformed agent, or two agents claiming one program, when the watcher starts.

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

## History and credits

This grew out of a resume script written for the author's own Rex setup and tested over several real restarts. Its approach is still the core of this one:

- the conversation each pane runs, from Claude Code's per-process session file, and for Codex from `codex resume <id>` or the conversation name in the pane's title, looked up in `session_index.jsonl` (which covers plain `codex` and `codex resume <name>`);
- a record keyed by Rex's pane IDs, which survive restarts;
- resuming once per new server, only into panes back at a shell prompt, never twice into one pane;
- one watcher at a time, the newest replacing an older or stuck one, and the Resume Agents action.

Two other projects solving the same problem had ideas worth adding, reimplemented here:

- [thomasschafer/dotfiles#11](https://github.com/thomasschafer/dotfiles/pull/11): finding a Codex conversation in Codex's state database, and checking that a Claude transcript exists before recording its ID;
- [sshtab](https://github.com/luongnv89/rex-extensions/tree/main/sshtab): forgetting an agent only after two missed checks, so quitting Rex doesn't erase it, and waiting for a steady prompt before typing.

## License

MIT. See [LICENSE](LICENSE).

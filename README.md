# rex-agent-resume

Brings your Claude Code and Codex conversations back into their [Rex](https://www.superlogical.com/rex) panes after the Rex server restarts: when you quit and reopen Rex, reboot, or update it.

Rex already restores your sessions, tabs, splits and each pane's folder, but the programs in them stop. This watches which conversation runs in which pane, and when a new server starts, types the line that resumes it:

```
pane was running   codex  (thread 0193f2a4…, started as `codex` and later named)
types              cd '/Users/you/project' && codex resume 0193f2a4-5b6c-7d8e-9f01-23456789abcd
```

## Install

Needs Rex on macOS or Linux, and `sqlite3` for the best Codex results (macOS has it).

```sh
git clone https://github.com/alokjha/rex-agent-resume ~/.config/rex/rex-agent-resume
~/.config/rex/rex-agent-resume/install.sh --key shift+cmd+r
```

`install.sh` backs up your `init.lua`, adds a marked block that loads `rex-agent-resume.lua` (and binds the key, if you pass `--key`), checks it with `rex config check`, and reloads the config. Without a key, the action is in the command palette as **Resume Agents**.

- Update: `git pull` in the clone, then `rex config reload`.
- Remove: `./install.sh --uninstall`. It takes the block out (with a backup) and stops the watcher. Its records in `~/.local/state/rex-agent-resume` are left for you to remove.

## How it works

Loading `rex-agent-resume.lua` starts `watcher.lua` in the background (`rex do --all`) each time the server loads its config. Only one watcher runs: the newest replaces an older one, and watchers started at the same moment settle on one before any of them types.

**Recording.** The watcher looks at every pane when a pane's program changes or a pane closes, and every 15 seconds, which catches Claude's `/clear` and `/resume`.

| Agent | Where the conversation ID comes from |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json`, which Claude keeps for each running process. A conversation is recorded once its transcript exists. |
| Codex | Codex's state database (`~/.codex/state_N.sqlite`): the threads in the pane's folder written since that Codex started. With several Codex in one folder, the thread name in the pane's title picks one; if it can't, the pane is skipped rather than guessed. If the database can't be read: `codex resume <UUID>` on the command line, then the title's name in `~/.codex/session_index.jsonl`. So plain `codex` and `codex resume <name>` are covered too. |

**Quitting.** Rex closes the agents a few seconds before its server stops. So that doesn't erase them, a pane's agent is forgotten only after two timed checks in a row miss it (or at once when the pane is closed).

**Restoring.** When the watcher first sees a new server, it moves what the last one ran to `restore.json`, then for each pane waits until:

- its foreground is the shell Rex started (zsh, bash or fish),
- the shell's line editor is reading keys, and
- the prompt line stays the same for a second.

Then it sends Ctrl-U (clearing anything on the line) and `cd '<folder>' && claude --resume <id>` or `codex resume <id>`, with Enter. Each pane is marked before it is typed into, so it's never typed into twice, and one conversation recorded in two panes is resumed in the first only. Panes not ready within 120 seconds of the server starting are left alone, and a macOS notification lists them.

**Resume Agents** (the action, or `rex do --all watcher.lua mode=resume`) types the last server's conversations into recorded panes that are at a prompt and not running their agent. Use it after the 120 seconds, or after quitting an agent by accident.

## Files

In `~/.local/state/rex-agent-resume/` (or `$XDG_STATE_HOME`), readable only by you:

- `state.json`: for each pane with an agent, the agent, conversation ID, folder and session name.
- `restore.json`: what the last server ran, which panes were typed into, whether the restore is `pending` or `finished` (a finished one is never run again), and why any pane failed.
- `watcher.log` (rotated at 1 MB) and `watcher.pid`.

No prompts, transcripts or environment are read or kept, apart from the Claude session file and Codex's thread IDs and names. Nothing leaves your machine.

`rex do --all watcher.lua mode=status` prints what is recorded.

## Limits

- Agents resume with their default options: flags such as `--model` or a permission mode aren't carried over.
- Only Claude Code and Codex. Only zsh, bash and fish panes are typed into.
- A pane in zsh vi command mode (not insert mode) may not take the line correctly.
- A folder holding a backslash isn't restored, as fish reads single-quoted backslashes differently.
- Two Codex panes in the same folder are told apart by the thread name in their titles. If both are unnamed or share a name, the pane keeps the last ID it was sure of, or isn't recorded. Give such threads distinct names with Codex's `/rename`. A Codex `SessionStart` hook can't fix this: Codex's shared background service runs hooks, with the environment of whichever pane started it, so a hook can't tell which pane it's for.
- `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are read from the Rex server's environment, not each agent's.
- Codex's database and session files are Codex's own formats and may change; each has a fallback, and the log says when one is used.
- `rex config check` runs `init.lua`, so it starts a watcher too. That one replaces the running watcher, which is harmless.

## Develop

```sh
lua5.1 test/run.lua       # or: rex do test/run.lua
```

`lib.lua` holds the logic that doesn't need Rex (parsing, choosing threads, when to forget, what to restore) and is what the tests cover. To try a restore without restarting Rex, point a watcher at a scratch folder whose `state.json` names another server, and pass `restore_test=1` to count the 120 seconds from now:

```sh
rex do --all watcher.lua state=/tmp/rar-test restore_test=1 notify=0
```

## History and credits

This grew out of a resume script written for one person's own Rex setup and tested over several real restarts. Its approach is still the core of this one:

- the conversation each pane runs, from Claude's per-process session file, and for Codex from `codex resume <UUID>` or the thread name in the pane's title looked up in `session_index.jsonl` (which covers plain `codex` and `codex resume <name>`);
- a record keyed by Rex's pane IDs, which survive restarts;
- resuming once per new server instance, only into panes back at a shell prompt, never twice into one pane;
- one watcher at a time, the newest replacing an older or stuck one, and the Resume Agents action.

Two other projects solving the same problem had ideas worth adding, reimplemented here:

- [thomasschafer/dotfiles#11](https://github.com/thomasschafer/dotfiles/pull/11): finding a Codex TUI's thread in Codex's state database, and checking a Claude transcript exists before recording its ID;
- [sshtab](https://github.com/luongnv89/rex-extensions/tree/main/sshtab): forgetting an agent only after two missed checks, so quitting Rex doesn't erase them, and waiting for a steady prompt before typing.

## License

MIT

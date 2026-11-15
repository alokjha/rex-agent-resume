# rex-agent-resume

Brings your Claude Code and Codex conversations back into their [Rex](https://www.superlogical.com/rex) panes after Rex is stopped completely and started again.

Rex brings back your sessions, tabs, splits and each pane's folder, but not the programs that ran in them: you get plain shells. This tool remembers which conversation ran in which pane, and once Rex is back, types the command that resumes it:

```
cd '/Users/you/code/app' && claude --resume 3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8
```

It works however the agent was started: `claude`, `claude --resume …`, `codex`, `codex resume <id>` or `codex resume <name>`.

## Requirements

- Rex, with its server restoring your sessions (the default).
- Claude Code and/or Codex, on the `PATH` of a new shell.
- `sqlite3` for the best Codex results (macOS includes it).

Tested on macOS with Rex 0.1.0 previews, Claude Code 2.1 and Codex 0.167 to 0.169.

## Install

```sh
git clone https://github.com/alokjha/rex-agent-resume ~/.config/rex/rex-agent-resume
~/.config/rex/rex-agent-resume/install.sh
```

The script backs up your `init.lua`, adds the lines that load the tool and bind **Resume Agents** (below) to `shift+cmd+r`, checks the result and reloads Rex. Keep the clone where you put it.

Or install by hand: clone it as above, then add to `~/.config/rex/init.lua`

```lua
require("rex-agent-resume")
rex.bind("shift+cmd+r", "resume_agents")
```

and run `rex config reload`. A clone elsewhere is loaded with `dofile("/path/to/rex-agent-resume/rex-agent-resume.lua")`.

Run only one tool that resumes agents: two would type each resume command twice.

## Check that it works

```sh
rex do --all ~/.config/rex/rex-agent-resume/watcher.lua mode=status
```

lists the panes it has recorded:

```
  api                  claude 3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8  /Users/you/code/api
  web                  codex  0193f2a4-5b6c-7d8e-9f01-23456789abcd  /Users/you/code/web
```

Then stop Rex completely and open it again. Each agent starts again within seconds of its pane's prompt appearing.

## Resume by hand

If a pane wasn't ready in time (within 120 seconds of a restart), press **Resume Agents**: your key, or the command palette. It resumes the last restart's conversations in their panes that are at a shell prompt, and prints what it did:

```
resumed 1, already running 8, not resumed 0
```

## Update and remove

- **Update:** `git -C ~/.config/rex/rex-agent-resume pull`, then `rex config reload`.
- **Remove:** `~/.config/rex/rex-agent-resume/install.sh --uninstall`. Installed by hand: delete the lines you added, reload, and [stop the watcher](docs.md#what-installsh-does).

## More

[docs.md](docs.md) explains [how it works](docs.md#how-it-works), [troubleshooting](docs.md#troubleshooting), [limits](docs.md#limits), and [adding another agent](docs.md#adding-an-agent).

## History and credits

This grew out of a resume script written for the author's own Rex setup and tested over several real restarts. Its approach is still the core of this one:

- the conversation each pane runs, from Claude Code's per-process session file, and for Codex from `codex resume <id>` or the conversation name in the pane's title, looked up in `session_index.jsonl` (which covers plain `codex` and `codex resume <name>`);
- a record keyed by Rex's pane IDs, which survive restarts;
- resuming once per new server, only into panes back at a shell prompt, never twice into one pane;
- one watcher at a time, the newest replacing an older or stuck one, and the Resume Agents action.

Two other projects solving the same problem had ideas worth adding, reimplemented here:

- [thomasschafer/dotfiles#11](https://github.com/thomasschafer/dotfiles/pull/11): finding a Codex conversation in Codex's state database, and checking that a Claude transcript exists before recording its ID;
- [sshtab](https://github.com/luongnv89/rex-extensions/tree/main/sshtab): forgetting an agent only after two missed checks, so stopping Rex doesn't erase it, and waiting for a steady prompt before typing.

## License

MIT. See [LICENSE](LICENSE).

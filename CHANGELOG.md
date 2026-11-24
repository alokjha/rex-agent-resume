# Changelog

## 0.1.1 (2026-11-24)

- Fix: when Rex stopped again while a restore was still running, such as a force quit right after a restart, the agents it hadn't finished were lost. The next restart now restores them too.

## 0.1.0 (2026-11-16)

First release.

- Records which Claude Code or Codex conversation runs in each Rex pane, when a pane's program changes and every 15 seconds.
- Finds Codex conversations from Codex's state database, with fallbacks to the command line and the tab title, so plain `codex` and `codex resume <name>` are covered.
- After the Rex server restarts, types the resume command into each pane once its shell prompt is ready, at most once per pane, within 120 seconds.
- Keeps agents recorded while the Rex server closes them as it stops.
- One folder per agent in `agents/`, each implementing the `Agent` protocol in `core/agent_protocol.lua`, so another agent can be added without touching the core. A broken agent is skipped with a warning; the others keep working.
- **Resume Agents** action for panes that weren't ready in time.
- `install.sh`: install (run again to rewrite) and `--uninstall`, with backups and a check of the result; or install by hand with `require("rex-agent-resume")`.

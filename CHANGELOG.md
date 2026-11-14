# Changelog

## 0.1.0 (unreleased)

First release.

- Records which Claude Code or Codex conversation runs in each Rex pane, when a pane's program changes and every 15 seconds.
- Finds Codex conversations from Codex's state database, with fallbacks to the command line and the tab title, so plain `codex` and `codex resume <name>` are covered.
- After the Rex server restarts, types the resume command into each pane once its shell prompt is ready, at most once per pane, within 120 seconds.
- Keeps agents recorded while Rex closes them on quit.
- One file per agent in `agents/`, behind a registry, so another agent can be added without touching the core.
- **Resume Agents** action for panes that weren't ready in time.
- `install.sh`: install, rewrite, `--update` and `--uninstall`, with backups and a check of the result; or install by hand with `require("rex-agent-resume")`.

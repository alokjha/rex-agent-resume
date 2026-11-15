#!/bin/sh
# Adds rex-agent-resume to Rex's init.lua, with shift+cmd+r for Resume Agents,
# or takes it out again.
#
#   ./install.sh              add it (run again to rewrite its block)
#   ./install.sh --uninstall  take it out and stop the watcher
#
# The file is $REX_CONFIG, else $XDG_CONFIG_HOME/rex/init.lua, else
# ~/.config/rex/init.lua. It is backed up before every change.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
here_real=$(cd "$here" && pwd -P) # with symlinks resolved, as a dotfiles setup may link it
config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex-agent-resume
begin='-- >>> rex-agent-resume >>>'
end='-- <<< rex-agent-resume <<<'

die() { echo "rex-agent-resume: $*" >&2; exit 1; }

# rex on PATH, else REX_BIN_DIR, else the one inside the macOS app.
rex=
if command -v rex >/dev/null 2>&1; then
  rex=rex
else
  for candidate in "${REX_BIN_DIR:-}/rex" \
    "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"; do
    if [ -x "$candidate" ]; then rex=$candidate; break; fi
  done
fi

backup_path=
backup() {
  [ -f "$config" ] || return 0
  backup_path="$config.bak-rex-agent-resume-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$config" "$backup_path"
  echo "Backed up $config to $backup_path"
}

reload() {
  if "$rex" --autostart=false server status >/dev/null 2>&1; then
    "$rex" --autostart=false config reload >/dev/null && echo "Reloaded Rex's config."
  else
    echo "Rex isn't running; the change applies when it next starts."
  fi
}

# The config without the block, and without the blank lines that leaves at its end.
without_block() {
  awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$config" \
    | awk 'NF { while (blanks > 0) { print ""; blanks-- } print; next } { blanks++ }'
}

case ${1:-} in
  "") action=install ;;
  --uninstall) action=uninstall ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) die "unknown option $1 (see --help)" ;;
esac
[ -n "$rex" ] || die "can't find the rex command. Install Rex first, or put rex on PATH."

if [ "$action" = uninstall ]; then
  if [ -f "$config" ] && grep -qxF -- "$begin" "$config"; then
    backup
    without_block > "$config.tmp" && mv "$config.tmp" "$config"
    echo "Took rex-agent-resume out of $config."
    reload
  else
    echo "rex-agent-resume isn't in $config."
  fi
  # The watcher runs on until stopped: the one in watcher.pid, if it's ours.
  pid=$(cat "$state/watcher.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ps -ww -o args= -p "$pid" 2>/dev/null | grep -qF -e "$here/watcher.lua" -e "$here_real/watcher.lua"; then
    kill "$pid" && echo "Stopped the watcher ($pid)."
  fi
  echo "Its records are kept in $state; delete that folder yourself if you no longer want them."
  exit 0
fi

command -v sqlite3 >/dev/null 2>&1 || echo "  note: sqlite3 isn't on PATH, so Codex conversations are found by their command line and title only."
command -v claude >/dev/null 2>&1 || command -v codex >/dev/null 2>&1 \
  || echo "  note: neither claude nor codex is on PATH here; resuming needs them on the PATH of a new shell."

mkdir -p "$(dirname "$config")"
if [ -f "$config" ] && ! "$rex" config check >/dev/null 2>&1; then
  die "'rex config check' already fails for $config; fix that first. Nothing was changed."
fi

# A clone beside init.lua is loaded with Rex's require; one elsewhere by its path.
if [ "$(cd "$(dirname "$config")/rex-agent-resume" 2>/dev/null && pwd -P)" = "$here_real" ]; then
  load_line='require("rex-agent-resume")'
else
  load_line="dofile(\"$(printf '%s' "$here/rex-agent-resume.lua" | sed 's/\\/\\\\/g; s/"/\\"/g')\")"
fi

backup
{
  if [ -f "$config" ]; then without_block; fi
} > "$config.tmp"
needs_blank_line=
if [ -s "$config.tmp" ]; then needs_blank_line=1; fi
{
  if [ -n "$needs_blank_line" ]; then echo; fi
  echo "$begin"
  echo "-- Resumes Claude Code and Codex in their panes after Rex restarts."
  echo "-- https://github.com/alokjha/rex-agent-resume"
  echo "$load_line"
  echo 'rex.bind("shift+cmd+r", "resume_agents")'
  echo "$end"
} >> "$config.tmp"
mv "$config.tmp" "$config"

if ! "$rex" config check >/dev/null 2>&1; then
  if [ -n "$backup_path" ]; then cp -p "$backup_path" "$config"; else rm -f "$config"; fi
  die "'rex config check' rejected the change, so $config was put back as it was."
fi
echo "Added rex-agent-resume to $config."
reload
echo "See what it has recorded with: rex do --all $here/watcher.lua mode=status"

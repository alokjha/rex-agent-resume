#!/bin/sh
# Adds rex-agent-resume to Rex's init.lua, or takes it out again.
#
#   ./install.sh                     add it
#   ./install.sh --key shift+cmd+r   add it, with a key for the Resume Agents action
#   ./install.sh --uninstall         take it out
#
# The file is $REX_CONFIG, else $XDG_CONFIG_HOME/rex/init.lua, else
# ~/.config/rex/init.lua. It is backed up before every change.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex-agent-resume
begin='-- >>> rex-agent-resume >>>'
end='-- <<< rex-agent-resume <<<'

rex=rex
if ! command -v rex >/dev/null 2>&1; then
  for c in "${REX_BIN_DIR:-}/rex" \
    "$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"; do
    if [ -x "$c" ]; then rex=$c; break; fi
  done
fi

die() { echo "rex-agent-resume: $*" >&2; exit 1; }

# A Lua string literal for $1.
lua_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

backup() {
  [ -f "$config" ] || return 0
  b="$config.bak-rex-agent-resume-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$config" "$b"
  echo "Backed up $config to $b"
}

reload() {
  if "$rex" --autostart=false server status >/dev/null 2>&1; then
    "$rex" --autostart=false config reload >/dev/null && echo "Reloaded Rex's config."
  else
    echo "Rex isn't running; the change applies when it next starts."
  fi
}

strip_block() { awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$config"; }

stop_watcher() {
  pid=$(cat "$state/watcher.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ps -ww -o args= -p "$pid" 2>/dev/null | grep -q "$here/watcher.lua"; then
    kill "$pid" && echo "Stopped the watcher ($pid)."
  fi
}

key=
uninstall=
while [ $# -gt 0 ]; do
  case $1 in
    --key) [ $# -ge 2 ] || die "--key needs a key, such as shift+cmd+r"; key=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

if [ -n "$uninstall" ]; then
  if [ ! -f "$config" ] || ! grep -qxF -- "$begin" "$config"; then
    echo "rex-agent-resume isn't in $config."
  else
    backup
    strip_block > "$config.tmp" && mv "$config.tmp" "$config"
    echo "Took rex-agent-resume out of $config."
    reload
  fi
  stop_watcher
  echo "Its records are kept in $state; remove that folder yourself if you no longer want them."
  exit 0
fi

command -v sqlite3 >/dev/null 2>&1 || echo "Note: sqlite3 isn't on PATH, so Codex sessions are found by their command line and title only."

mkdir -p "$(dirname "$config")"
if [ -f "$config" ] && grep -qxF -- "$begin" "$config"; then
  echo "rex-agent-resume is already in $config. To change it, run --uninstall first."
  exit 0
fi
if [ -f "$config" ] && ! "$rex" config check >/dev/null 2>&1; then
  die "'rex config check' already fails for $config; fix that first. Nothing was changed."
fi

backup
gap=
if [ -s "$config" ]; then gap=1; fi
{
  if [ -n "$gap" ]; then echo; fi
  echo "$begin"
  echo "-- Resumes Claude Code and Codex in their panes after Rex restarts."
  echo "-- https://github.com/alokjha/rex-agent-resume"
  echo "dofile($(lua_string "$here/rex-agent-resume.lua"))"
  [ -n "$key" ] && echo "rex.bind($(lua_string "$key"), \"resume_agents\")"
  echo "$end"
} >> "$config"

if ! "$rex" config check >/dev/null 2>&1; then
  strip_block > "$config.tmp" && mv "$config.tmp" "$config"
  die "'rex config check' rejected the change, so it was taken out again."
fi
echo "Added rex-agent-resume to $config."
reload
echo "The log is $state/watcher.log."

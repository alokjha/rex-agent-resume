#!/bin/sh
# Adds rex-agent-resume to Rex's init.lua, updates it, or takes it out again.
#
#   ./install.sh                     add it (or, run again, rewrite its block)
#   ./install.sh --key shift+cmd+r   the same, with a key for the Resume Agents action
#   ./install.sh --update            pull the latest version and reload Rex's config
#   ./install.sh --uninstall         take it out and stop the watcher
#
# The file is $REX_CONFIG, else $XDG_CONFIG_HOME/rex/init.lua, else
# ~/.config/rex/init.lua. It is backed up before every change.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
here_real=$(cd "$here" && pwd -P) # the same folder with symlinks resolved, as a dotfiles setup may link it
config=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
state=${XDG_STATE_HOME:-$HOME/.local/state}/rex-agent-resume
begin='-- >>> rex-agent-resume >>>'
end='-- <<< rex-agent-resume <<<'

backup_path=

die() { echo "rex-agent-resume: $*" >&2; exit 1; }
note() { echo "  note: $*"; }

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

# A Lua string literal for $1.
lua_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

# A key with its modifiers in a fixed order, so "cmd+shift+r" and
# "shift+cmd+r" compare equal.
normalize_key() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | awk -F+ '{
    n = split($0, parts, "+"); key = parts[n]; mods = ""
    split("ctrl alt shift cmd", order, " ")
    for (i = 1; i <= 4; i++) for (j = 1; j < n; j++) {
      m = parts[j]; if (m == "control") m = "ctrl"; if (m == "option" || m == "opt") m = "alt"
      if (m == "command" || m == "super") m = "cmd"
      if (m == order[i]) mods = mods order[i] "+"
    }
    print mods key }'
}

server_running() { [ -n "$rex" ] && "$rex" --autostart=false server status >/dev/null 2>&1; }

backup() {
  [ -f "$config" ] || return 0
  backup_path="$config.bak-rex-agent-resume-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$config" "$backup_path"
  echo "Backed up $config to $backup_path"
}

reload() {
  if server_running; then
    "$rex" --autostart=false config reload >/dev/null && echo "Reloaded Rex's config."
  else
    echo "Rex isn't running; the change applies when it next starts."
  fi
}

strip_block() { awk -v b="$begin" -v e="$end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$config"; }

watcher_pid() {
  pid=$(cat "$state/watcher.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ps -ww -o args= -p "$pid" 2>/dev/null | grep -qF -e "$here/watcher.lua" -e "$here_real/watcher.lua"; then
    echo "$pid"
  fi
}

stop_watcher() {
  pid=$(watcher_pid)
  if [ -n "$pid" ]; then kill "$pid" && echo "Stopped the watcher ($pid)."; fi
}

# Names the other background Rex scripts that are running (`rex ... do ...
# script.lua`), whatever they are. Tools that resume agents after a restart run
# this way; two of them would type the resume command twice into each pane.
warn_about_other_rex_scripts() {
  others=$(ps -axww -o args= 2>/dev/null \
    | grep -E '(^|/)rex( [^ ]+)* do ' \
    | grep -vF -e "$here/watcher.lua" -e "$here_real/watcher.lua" \
    | grep -oE '[^ ]+\.lua' | sort -u || true)
  [ -n "$others" ] || return 0
  note "other background Rex scripts are running:"
  printf '%s\n' "$others" | while read -r script; do note "  $script"; done
  note "If one of them also resumes agents after a restart, turn it off or remove it:"
  note "two such tools would type the resume command twice into each pane."
}

# Waits for the watcher the reload started (not the one from before it, whose
# pid is $1) to start and record, then says what it found.
verify() {
  server_running || return 0
  tries=0
  while [ $tries -lt 15 ]; do
    pid=$(watcher_pid)
    if [ -n "$pid" ] && [ "$pid" != "${1:-}" ]; then break; fi
    sleep 1; tries=$((tries + 1))
  done
  if [ -z "$pid" ] || [ "$pid" = "${1:-}" ]; then
    echo "The watcher hasn't started. See $state/watcher.log, and check that 'rex config check' passes."
    return 1
  fi
  sleep 3
  agents=$("$rex" --autostart=false do --all "$here/watcher.lua" mode=status "state=$state" 2>/dev/null \
    | grep -cE '^  .* (claude|codex) ' || true)
  echo "The watcher is running (pid $pid) and has recorded $agents agent pane(s)."
  echo "See them with: rex do --all $here/watcher.lua mode=status"
}

key=
action=install
while [ $# -gt 0 ]; do
  case $1 in
    --key) [ $# -ge 2 ] || die "--key needs a key, such as shift+cmd+r"; key=$2; shift 2 ;;
    --uninstall) action=uninstall; shift ;;
    --update) action=update; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

[ -n "$rex" ] || die "can't find the rex command. Install Rex first, or put rex on PATH."

case $action in
uninstall)
  if [ ! -f "$config" ] || ! grep -qxF -- "$begin" "$config"; then
    echo "rex-agent-resume isn't in $config."
  else
    backup
    strip_block > "$config.tmp" && mv "$config.tmp" "$config"
    echo "Took rex-agent-resume out of $config."
    reload
  fi
  stop_watcher
  echo "Its records are kept in $state; delete that folder yourself if you no longer want them."
  exit 0
  ;;
update)
  [ -d "$here/.git" ] || die "$here isn't a git clone, so it can't be updated with git."
  git -C "$here" pull --ff-only
  previous_watcher=$(watcher_pid)
  reload
  verify "$previous_watcher"
  exit 0
  ;;
esac

# Install, or rewrite the block of an earlier install.
command -v sqlite3 >/dev/null 2>&1 || note "sqlite3 isn't on PATH, so Codex conversations are found by their command line and title only."
command -v claude >/dev/null 2>&1 || command -v codex >/dev/null 2>&1 \
  || note "neither claude nor codex is on PATH here; resuming needs them on the PATH of a new shell."

mkdir -p "$(dirname "$config")"
if [ -f "$config" ] && ! "$rex" config check >/dev/null 2>&1; then
  die "'rex config check' already fails for $config; fix that first. Nothing was changed."
fi

if [ -n "$key" ] && server_running; then
  wanted=$(normalize_key "$key")
  bound_to=$("$rex" --autostart=false keymap 2>/dev/null | while read -r bound action_name _; do
    if [ "$(normalize_key "$bound")" = "$wanted" ]; then echo "$action_name"; fi
  done | head -1)
  if [ -n "$bound_to" ] && [ "$bound_to" != "resume_agents" ]; then
    die "$key is already bound to '$bound_to'. Pick another key with --key, or leave --key out."
  fi
fi

# A clone beside init.lua, as <config folder>/rex-agent-resume, is loaded with
# Rex's own require, as when installing by hand; one elsewhere by its path.
beside_config=$(cd "$(dirname "$config")/rex-agent-resume" 2>/dev/null && pwd -P || true)
if [ "$beside_config" = "$here_real" ]; then
  load_line='require("rex-agent-resume")'
else
  load_line="dofile($(lua_string "$here/rex-agent-resume.lua"))"
fi

was_installed=
if [ -f "$config" ] && grep -qxF -- "$begin" "$config"; then was_installed=1; fi

backup
# The file without any earlier block, and without the blank lines that leaves at its end.
if [ -f "$config" ]; then
  strip_block | awk 'NF { while (blanks > 0) { print ""; blanks-- } print; next } { blanks++ }' > "$config.tmp"
else
  : > "$config.tmp"
fi
{
  if [ -s "$config.tmp" ]; then echo; fi
  echo "$begin"
  echo "-- Resumes Claude Code and Codex in their panes after Rex restarts."
  echo "-- https://github.com/alokjha/rex-agent-resume"
  echo "$load_line"
  if [ -n "$key" ]; then echo "rex.bind($(lua_string "$key"), \"resume_agents\")"; fi
  echo "$end"
} >> "$config.tmp"
mv "$config.tmp" "$config"

if ! "$rex" config check >/dev/null 2>&1; then
  if [ -n "$backup_path" ]; then cp -p "$backup_path" "$config"; else rm -f "$config"; fi
  die "'rex config check' rejected the change, so $config was put back as it was."
fi
if [ -n "$was_installed" ]; then echo "Rewrote the rex-agent-resume block in $config."
else echo "Added rex-agent-resume to $config."; fi
warn_about_other_rex_scripts
previous_watcher=$(watcher_pid)
reload
verify "$previous_watcher"

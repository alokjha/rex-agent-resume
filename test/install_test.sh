#!/bin/sh
# Tests for install.sh. Runs it against scratch config files with a fake `rex`
# on PATH, so it needs no Rex server:  sh test/install_test.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
installer="$root/install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake rex. FAKE_SERVER=up makes `server status` succeed; a config holding
# BROKEN fails `config check`; FAKE_REJECT_BLOCK=1 fails it once the block is
# in; FAKE_KEYMAP names a file printed by `keymap`.
mkdir -p "$work/bin"
cat > "$work/bin/rex" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in --autostart=*) shift ;; *) break ;; esac; done
case "$1" in
  server) [ "${FAKE_SERVER:-down}" = up ] ;;
  config)
    case "$2" in
      check)
        if grep -q BROKEN "$REX_CONFIG" 2>/dev/null; then exit 1; fi
        if [ -n "${FAKE_REJECT_BLOCK:-}" ] && grep -q 'rex-agent-resume >>>' "$REX_CONFIG" 2>/dev/null; then exit 1; fi
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  keymap) cat "${FAKE_KEYMAP:-/dev/null}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/bin/rex"

passed=0 failed=0
fail() { echo "FAIL $test_name: $*"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# A fresh case: its own config folder, state folder and HOME.
start() {
  test_name=$1
  case_dir="$work/$test_name"
  mkdir -p "$case_dir/config" "$case_dir/home"
  config="$case_dir/config/init.lua"
  unset FAKE_SERVER FAKE_REJECT_BLOCK FAKE_KEYMAP
}

run_installer() {
  output=$(PATH="$work/bin:/usr/bin:/bin" HOME="$case_dir/home" REX_CONFIG="$config" \
    XDG_STATE_HOME="$case_dir/state" REX_BIN_DIR= sh "$installer" "$@" 2>&1)
  status=$?
}

expect_status() { if [ "$status" -ne "$1" ]; then fail "exit $status, want $1: $output"; return 1; fi; }
expect_file() { # expect_file <expected contents>
  expected=$(printf '%s' "$1")
  actual=$(cat "$config" 2>/dev/null)
  if [ "$actual" != "$expected" ]; then
    fail "config differs"
    printf -- '--- want:\n%s\n--- got:\n%s\n---\n' "$expected" "$actual"
    return 1
  fi
}
backups() { find "$case_dir/config" -name 'init.lua.bak-rex-agent-resume-*' | wc -l | tr -d ' '; }

block() { # block [key]
  printf '%s\n' '-- >>> rex-agent-resume >>>' \
    '-- Resumes Claude Code and Codex in their panes after Rex restarts.' \
    '-- https://github.com/alokjha/rex-agent-resume' \
    "dofile(\"$root/rex-agent-resume.lua\")"
  if [ -n "${1:-}" ]; then printf 'rex.bind("%s", "resume_agents")\n' "$1"; fi
  printf '%s\n' '-- <<< rex-agent-resume <<<'
}

mine='-- my config
rex.bind("cmd+k", "com.superlogical.terminal.clear")


-- two blank lines above stay'

# --- the tests ---------------------------------------------------------------

start fresh_install
run_installer
expect_status 0 && expect_file "$(block)" && [ "$(backups)" = 0 ] && pass || fail "a new file needs no backup"

start keeps_existing_config
printf '%s\n' "$mine" > "$config"
run_installer
expect_status 0 && expect_file "$mine

$(block)" && [ "$(backups)" = 1 ] && pass || fail "one backup expected"
backup=$(find "$case_dir/config" -name 'init.lua.bak-rex-agent-resume-*')
[ "$(cat "$backup")" = "$mine" ] && pass || fail "the backup isn't the original file"

start rerun_changes_and_drops_key
printf '%s\n' "$mine" > "$config"
run_installer --key ctrl+alt+r
expect_status 0 && expect_file "$mine

$(block ctrl+alt+r)" && pass
run_installer
expect_status 0 && expect_file "$mine

$(block)" && pass
[ "$(grep -c 'rex-agent-resume >>>' "$config")" = 1 ] && pass || fail "more than one block"

start refuses_taken_key
printf '%s\n' "$mine" > "$config"
printf 'shift+cmd+k  session.switch  -  init.lua:5\n' > "$case_dir/keymap"
FAKE_SERVER=up FAKE_KEYMAP="$case_dir/keymap"; export FAKE_SERVER FAKE_KEYMAP
run_installer --key cmd+shift+k
expect_status 1 && expect_file "$mine" && [ "$(backups)" = 0 ] && pass || fail "a refused key changed something"
case $output in *"already bound to 'session.switch'"*) pass ;; *) fail "no reason given: $output" ;; esac

start accepts_key_already_ours
printf 'shift+cmd+r  resume_agents  -  init.lua:9\n' > "$case_dir/keymap"
FAKE_SERVER=up FAKE_KEYMAP="$case_dir/keymap"; export FAKE_SERVER FAKE_KEYMAP
printf '%s\n' "$mine" > "$config"
# The server is "up" but no watcher will start, so the final check reports that.
run_installer --key shift+cmd+r
case $output in *"already bound"*) fail "refused its own key" ;; *) pass ;; esac
grep -q 'rex.bind("shift+cmd+r", "resume_agents")' "$config" && pass || fail "key not written"

start refuses_broken_config
printf -- '-- BROKEN\n' > "$config"
run_installer
expect_status 1 && expect_file "-- BROKEN" && [ "$(backups)" = 0 ] && pass || fail "a broken config was changed"

start restores_on_rejected_change
printf '%s\n' "$mine" > "$config"
FAKE_REJECT_BLOCK=1; export FAKE_REJECT_BLOCK
run_installer
expect_status 1 && expect_file "$mine" && pass

start require_when_beside_config
ln -s "$root" "$case_dir/config/rex-agent-resume"
run_installer
expect_status 0 && grep -qx 'require("rex-agent-resume")' "$config" && ! grep -q dofile "$config" && pass \
  || fail "a clone beside init.lua should be loaded with require"

start uninstall_restores_config
printf '%s\n' "$mine" > "$config"
run_installer --key ctrl+alt+r
run_installer --uninstall
expect_status 0 && grep -q 'rex-agent-resume' "$config" && fail "block left behind" || pass
[ "$(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$config")" = "$mine" ] && pass || fail "user lines changed"

start uninstall_when_absent
printf '%s\n' "$mine" > "$config"
run_installer --uninstall
expect_status 0 && expect_file "$mine" && pass
case $output in *"isn't in"*) pass ;; *) fail "no message: $output" ;; esac

start no_rex
output=$(PATH="/usr/bin:/bin" HOME="$case_dir/home" REX_CONFIG="$config" REX_BIN_DIR= sh "$installer" 2>&1)
status=$?
expect_status 1 && case $output in *"can't find the rex command"*) pass ;; *) fail "unclear error: $output" ;; esac

start unknown_option
run_installer --bogus
expect_status 1 && pass

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

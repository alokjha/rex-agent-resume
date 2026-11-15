#!/bin/sh
# Tests for install.sh. Runs it against scratch config files with a fake `rex`
# on PATH, so it needs no Rex server:  sh test/install_test.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
installer="$root/install.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fake rex. Its server is never running. A config holding BROKEN fails
# `config check`; FAKE_REJECT_BLOCK=1 fails it once the block is in.
mkdir -p "$work/bin"
cat > "$work/bin/rex" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in --autostart=*) shift ;; *) break ;; esac; done
case "$1" in
  server) exit 1 ;;
  config)
    case "$2" in
      check)
        if grep -q BROKEN "$REX_CONFIG" 2>/dev/null; then exit 1; fi
        if [ -n "${FAKE_REJECT_BLOCK:-}" ] && grep -q 'rex-agent-resume >>>' "$REX_CONFIG" 2>/dev/null; then exit 1; fi
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
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
  unset FAKE_REJECT_BLOCK
}

run_installer() {
  output=$(PATH="$work/bin:/usr/bin:/bin" HOME="$case_dir/home" REX_CONFIG="$config" \
    XDG_STATE_HOME="$case_dir/state" REX_BIN_DIR="" sh "$installer" "$@" 2>&1)
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

block() {
  printf '%s\n' '-- >>> rex-agent-resume >>>' \
    '-- Resumes Claude Code and Codex in their panes after Rex restarts.' \
    '-- https://github.com/alokjha/rex-agent-resume' \
    "dofile(\"$root/rex-agent-resume.lua\")" \
    'rex.bind("shift+cmd+r", "resume_agents")' \
    '-- <<< rex-agent-resume <<<'
}

mine='-- my config
rex.bind("cmd+k", "com.superlogical.terminal.clear")


-- two blank lines above stay'

# --- the tests ---------------------------------------------------------------

start fresh_install
run_installer
if expect_status 0 && expect_file "$(block)" && [ "$(backups)" = 0 ]; then pass; else fail "a new file needs no backup"; fi

start keeps_existing_config
printf '%s\n' "$mine" > "$config"
run_installer
if expect_status 0 && expect_file "$mine

$(block)" && [ "$(backups)" = 1 ]; then pass; else fail "one backup expected"; fi
backup=$(find "$case_dir/config" -name 'init.lua.bak-rex-agent-resume-*')
if [ "$(cat "$backup")" = "$mine" ]; then pass; else fail "the backup isn't the original file"; fi

start rerun_keeps_one_block
printf '%s\n' "$mine" > "$config"
run_installer
run_installer
expect_status 0 && expect_file "$mine

$(block)" && pass

start refuses_broken_config
printf -- '-- BROKEN\n' > "$config"
run_installer
if expect_status 1 && expect_file "-- BROKEN" && [ "$(backups)" = 0 ]; then pass; else fail "a broken config was changed"; fi

start restores_on_rejected_change
printf '%s\n' "$mine" > "$config"
FAKE_REJECT_BLOCK=1; export FAKE_REJECT_BLOCK
run_installer
expect_status 1 && expect_file "$mine" && pass

start require_when_beside_config
ln -s "$root" "$case_dir/config/rex-agent-resume"
run_installer
if expect_status 0 && grep -qx 'require("rex-agent-resume")' "$config" && ! grep -q dofile "$config"; then pass
else fail "a clone beside init.lua should be loaded with require"; fi

start uninstall_restores_config
printf '%s\n' "$mine" > "$config"
run_installer
run_installer --uninstall
if expect_status 0 && ! grep -q "rex-agent-resume" "$config"; then pass; else fail "block left behind"; fi
if [ "$(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$config")" = "$mine" ]; then pass; else fail "user lines changed"; fi

start uninstall_when_absent
printf '%s\n' "$mine" > "$config"
run_installer --uninstall
expect_status 0 && expect_file "$mine" && pass

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

#!/usr/bin/env bash
# Automated tests for claude-rc-keepalive. NO real claude, tmux, curl, pgrep or systemctl is called:
# fake executables ("stubs") are placed at the front of the PATH, in a temporary directory removed at the end;
# /proc and /proc/meminfo are replaced by fake files (CLAUDE_RC_PROC_ROOT, CLAUDE_RC_MEMINFO).
# Run on Linux (or WSL): a few tests (file permissions, flock lock) are skipped elsewhere.
# Usage: bash tests/run-tests.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'pkill -f "claude-rc-test-bg-$$" 2>/dev/null; rm -rf "$T"' EXIT
STUBS="$T/stubs"; mkdir -p "$STUBS" "$T/home" "$T/config"
LINUX=0; [ "$(uname -s)" = Linux ] && LINUX=1

export HOME="$T/home"
export CLAUDE_RC_CONFIG_DIR="$T/config" CLAUDE_RC_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" SCREEN="$T/screen.txt"
export CLAUDE_RC_PROC_ROOT="$T/proc" CLAUDE_RC_MEMINFO="$T/meminfo" CLAUDE_RC_ALLOW_TMP=1 RC_AUTH_CACHE_SECONDS=0 CLAUDE_CONFIG_DIR="$T/cc"   # (test directories under /tmp)
export PATH="$STUBS:$PATH"
printf 'MemTotal: 8000000 kB\nMemAvailable: 6000000 kB\n' > "$T/meminfo"
printf 'MemTotal: 8000000 kB\nMemAvailable: 500000 kB\n' > "$T/meminfo.low"

# ---------- fake executables ----------
cat > "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$STUB_LOG"
case "${1:-}" in
  auth)
    if [ "${STUB_AUTH:-ok}" = ok ]; then printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n'
    else printf '{\n  "loggedIn": false\n}\n'; fi
    exit 0 ;;
  remote-control)
    if printf '%s\n' "$@" | grep -qx -- '--continue'; then sleep "${STUB_CONTINUE_SLEEP:-0}"; exit "${STUB_CONTINUE_RC:-0}"
    else exit "${STUB_FRESH_RC:-0}"; fi ;;
esac
EOF
cat > "$STUBS/curl"  <<'EOF'
#!/usr/bin/env bash
[ "${STUB_NET:-ok}" = ok ]
EOF
cat > "$STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "${STUB_ALIVE:-0}" = 1 ] && { echo "${STUB_PID:-4242}"; exit 0; }
exit 1
EOF
cat > "$STUBS/tmux"  <<'EOF'
#!/usr/bin/env bash
echo "tmux $*" >> "$STUB_LOG"
case "${1:-}" in
  has-session) exit "${STUB_TMUX_HAS:-1}" ;;
  new-session) [ -n "${STUB_TMUX_SLEEP:-}" ] && sleep "$STUB_TMUX_SLEEP"
               [ -n "${STUB_TMUX_BG:-}" ] && { ( exec -a "claude-rc-test-bg-$PPID_MARK" sleep 5 ) >/dev/null 2>&1 & }
               exit "${STUB_TMUX_NEW_RC:-0}" ;;
  *) exit 0 ;;
esac
EOF
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"; exit 0
EOF
chmod +x "$STUBS"/*

# ---------- test configuration ----------
cat > "$CLAUDE_RC_CONFIG_DIR/t1.env" <<EOF
RC_NAME="T1"
RC_DIR="$T/work"
CLAUDE_BIN="$STUBS/claude"
RC_CONTINUE_FAIL_SECONDS=3
EOF
cat > "$T/bypass.env" <<EOF
RC_NAME="B"
RC_DIR="$T/workb"
RC_PERMISSION_MODE="bypassPermissions"
EOF

ENSURE="$ROOT/bin/claude-rc-ensure"; RUN="$ROOT/bin/claude-rc-run"; CTL="$ROOT/bin/claude-rc-ctl"
pass=0; fail=0; skip=0
check() { local name=$1; shift; if "$@"; then echo "  ok     $name"; pass=$((pass + 1)); else echo "  FAIL   $name"; fail=$((fail + 1)); fi; }
skipped() { echo "  skipped $1"; skip=$((skip + 1)); }
reset() { rm -rf "$CLAUDE_RC_STATE_DIR" "$T/work" "$T/proc"; : > "$STUB_LOG"; rm -f "$SCREEN"
          for x in t2 t3 t4 t5 t6 example; do rm -f "$CLAUDE_RC_CONFIG_DIR/$x.env"; done
          export CLAUDE_RC_MEMINFO="$T/meminfo" CLAUDE_RC_ALLOW_TMP=1
          unset STUB_AUTH STUB_NET STUB_ALIVE STUB_PID STUB_CONTINUE_RC STUB_CONTINUE_SLEEP STUB_FRESH_RC STUB_TMUX_HAS STUB_TMUX_SLEEP STUB_TMUX_BG CLAUDE_RC_NOW CLAUDE_RC_SCREEN_FILE RC_FORCE_FRESH RC_STOP_WAIT RC_FALLBACK RC_MIN_AVAILABLE_MB RC_LOG_MAX_BYTES RC_ALLOW_SAME_NAME RC_AUTH_FRESH RC_AUTH_MODE; rm -rf "$T/cc"; }
# alive [directory]: a fake server (pid 4242) works in that directory (default: t1's)
alive() { export STUB_ALIVE=1; rm -rf "$T/proc"; mkdir -p "$T/proc/4242"; ln -sfn "${1:-$T/work}" "$T/proc/4242/cwd"; }
n() { grep -c -- "$1" "$STUB_LOG" || true; }               # number of calls containing the pattern
logged() { grep -q -- "$1" "$CLAUDE_RC_STATE_DIR/t1.log" 2>/dev/null; }
exit_is() { local want=$1; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }
screen() { printf '%s\n' "$1" > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"; }
NOREC='Error: No recent session found in this directory or its worktrees. Run `claude remote-control` to start a new one.'
mode_of() { stat -c %a "$1"; }

echo "== configuration"
reset
cp "$T/bypass.env" "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "bypassPermissions mode refused (code 65)"                  exit_is 65 bash "$ENSURE" bypass
rm -f "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "invalid identifier refused (code 64)"                      exit_is 64 bash "$ENSURE" "Bad ID"
check "configuration missing (code 66)"                           exit_is 66 bash "$ENSURE" unknown
printf 'RC_NAME="T1"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "name already used by another instance (code 67)"           exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/work/"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "directory already used (even with a trailing \"/\") (code 67)" exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "two instances with distinct names and directories: accepted" exit_is 0 bash "$ENSURE" t2
rm -f "$CLAUDE_RC_CONFIG_DIR/t2.env"

echo "== free session names, durable directories, settings"
reset
# (accented characters in the next fixtures are deliberate: they test that Unicode names are handled)
printf 'RC_NAME="Projet.ai/Démo  éà - test"\nRC_DIR="%s/w2"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "name with spaces, \"/\", accents and double space: accepted" exit_is 0 bash "$ENSURE" t2
printf 'RC_NAME="-option"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "name starting with \"-\" refused (code 68)"                exit_is 68 bash "$ENSURE" t2
{ printf 'RC_NAME=$'"'"'a\\nb'"'"'\nRC_DIR="%s/w2"\n' "$T"; } > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "name with a newline refused (code 68)"                     exit_is 68 bash "$ENSURE" t2
printf 'RC_NAME="%s"\nRC_DIR="%s/w2"\n' "$(printf 'x%.0s' $(seq 121))" "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "name longer than 120 characters refused (code 68)"         exit_is 68 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="relative/w2"\n' > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "relative directory refused (code 69)"                      exit_is 69 bash "$ENSURE" t2
for d in /tmp/x /var/tmp/x /dev/shm/x /run/x; do
  printf 'RC_NAME="T2"\nRC_DIR="%s"\n' "$d" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
  check "temporary directory $d refused (code 69)"                bash -c "env -u CLAUDE_RC_ALLOW_TMP bash '$ENSURE' t2 >/dev/null 2>&1; [ \$? -eq 69 ]"
done
printf 'RC_NAME="T2"\nRC_DIR="/home/u/claude-rc/sessions/t2"\n' > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "durable directory (outside /tmp) accepted by validation"   bash -c "env -u CLAUDE_RC_ALLOW_TMP bash -c '. \"$ROOT/lib/common.sh\"; rc_valid_dir /home/u/claude-rc/sessions/t2'"
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nRC_FALLBACK="always"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "invalid RC_FALLBACK refused (code 70)"                     exit_is 70 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nRC_MAX_LAUNCHES="many"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "invalid numeric setting refused (code 71)"                 exit_is 71 bash "$ENSURE" t2
rm -f "$CLAUDE_RC_CONFIG_DIR/t2.env"

echo "== claude-rc-ensure: decisions"
reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; date > "$CLAUDE_RC_STATE_DIR/t1.stop"
check "manual stop: nothing is launched (code 0)"                 exit_is 0 bash "$ENSURE" t1
check "manual stop: tmux not called"                              test "$(n 'new-session')" = 0
check "manual stop: logged"                                       logged "manual stop active"

reset; alive
check "session already running, login OK (code 0)"               exit_is 0 bash "$ENSURE" t1
check "session running: no duplicate launched"                    test "$(n 'new-session')" = 0
check "session running: logged"                                   logged "is running"
check "session running (adopted): marked \"already started\""     test -e "$CLAUDE_RC_STATE_DIR/t1.started"
reset; alive; export STUB_AUTH=ko
check "session running but login invalid (code 3)"                exit_is 3 bash "$ENSURE" t1

reset; export STUB_NET=ko
check "network down: no launch, code 0"                           exit_is 0 bash "$ENSURE" t1
check "network down: tmux not called"                             test "$(n 'new-session')" = 0
check "network down: logged"                                      logged "unreachable"

reset; export STUB_AUTH=ko
check "invalid login: nothing is launched (code 3)"               exit_is 3 bash "$ENSURE" t1
check "invalid login: tmux not called"                            test "$(n 'new-session')" = 0

reset
check "nominal case: launch (code 0)"                             exit_is 0 bash "$ENSURE" t1
check "launch: tmux new-session -s rc-t1"                         test "$(n 'new-session -d -s rc-t1')" = 1
check "launch: runs claude-rc-run (without --fresh)"              test "$(n 'claude-rc-run t1$')" = 1
check "launch: working directory created"                         test -d "$T/work"
check "launch: 1 entry in the anti-loop counter"                  test "$(grep -c . "$CLAUDE_RC_STATE_DIR/t1.launches")" = 1

reset; export RC_FORCE_FRESH=1
check "RC_FORCE_FRESH=1: the launch carries --fresh"              bash -c "bash '$ENSURE' t1 && grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"

reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "anti-loop: 3 launches in 10 min -> pause (code 4)"         exit_is 4 bash "$ENSURE" t1
check "anti-loop: tmux not called"                                test "$(n 'new-session')" = 0
export CLAUDE_RC_NOW=1600
check "anti-loop: 10 min later -> AUTOMATIC resume"               exit_is 0 bash "$ENSURE" t1
check "anti-loop: launch actually happened"                       test "$(n 'new-session')" = 1

echo "== detection of an existing server by its working DIRECTORY"
reset; alive; printf 'RC_NAME="Any other name"\nRC_DIR="%s/work"\n' "$T" > "$T/other.env"
check "server in the same directory (different name): adopted, no duplicate" bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
reset; alive "$T/elsewhere"
check "server in ANOTHER directory (name unreadable): ignored (launch)" bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; alive "$T/work/subdir"
check "server in a SUBDIRECTORY: distinct (launch)"               bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; mkdir -p "$T/real" "$T/work"; rmdir "$T/work"; ln -sfn "$T/real" "$T/work"; alive "$T/real"
check "directory configured through a symbolic link: recognised"  bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
rm -f "$T/work"; rm -rf "$T/real"
reset; alive
check "ctl status: shows the server's pid and memory"             bash -c "'$CTL' status t1 | grep -q 'server process     : running (pid 4242)'"
check "ctl status: shows the fallback, never by default"          bash -c "'$CTL' status t1 | grep -q 'fallback           : never'"

echo "== duplicate names (all launch methods)"
# fakeproc <pid> <directory> <argument...>: a fake process (NUL-separated command line + working directory)
fakeproc() { local pid=$1 cwd=$2; shift 2; mkdir -p "$T/proc/$pid" "$cwd"; ln -sfn "$cwd" "$T/proc/$pid/cwd"; printf '%s\0' "$@" > "$T/proc/$pid/cmdline"; }
NOM="Name with spaces é"

reset; fakeproc 5001 "$T/a" claude remote-control --name "Alpha" --spawn same-dir
check "list: a unique name -> no warning"                           bash -c "! '$CTL' list | grep -q 'DUPLICATES'"

reset; fakeproc 5001 "$T/a" /usr/bin/claude remote-control --name "$NOM" --spawn same-dir
fakeproc 5002 "$T/b" /home/x/.local/bin/claude --remote-control "$NOM" --model opus
check "list: same name, server and interactive forms -> DUPLICATES" bash -c "'$CTL' list | grep -q 'DUPLICATES'"
check "list: the name with spaces and accent is read in full"       bash -c "'$CTL' list | grep -qF '\"$NOM\"'"
check "list: both pids and both forms are shown"                    bash -c "o=\$('$CTL' list); echo \"\$o\" | grep -q 'pid 5001 .*server' && echo \"\$o\" | grep -q 'pid 5002 .*interactive'"
check "list: exit code 0 despite the duplicates"                    exit_is 0 "$CTL" list

reset; fakeproc 5001 "$T/a" claude remote-control --name "Alpha"
fakeproc 5003 "$T/c" claude --name "Alpha" --model opus
fakeproc 5004 "$T/d" claude --remote-control --model opus
fakeproc 5005 "$T/e" bash -c "claude --remote-control Alpha"
check "list: ordinary \"claude --name\", --remote-control without a name and other programs do not count" bash -c "! '$CTL' list | grep -q 'DUPLICATES'"

reset; fakeproc 5006 "$T/elsewhere" claude --remote-control T1 --model opus
check "ensure: ANOTHER process uses the name -> nothing is launched (code 9)" exit_is 9 bash "$ENSURE" t1
check "ensure: duplicate -> tmux not called"                        test "$(n 'new-session')" = 0
check "ensure: duplicate -> logged with the pid and the directory"  logged "already uses the name 'T1': pid 5006 (interactive, $T/elsewhere)"
check "ensure: duplicate -> the launch is not counted"              bash -c "! test -s '$CLAUDE_RC_STATE_DIR/t1.launches'"

reset; fakeproc 5007 "$T/elsewhere" claude remote-control --name T1 --spawn same-dir
check "ensure: a server of the same name in another directory -> refused (code 9)" exit_is 9 bash "$ENSURE" t1

reset; fakeproc 5006 "$T/elsewhere" claude --remote-control T1; export RC_ALLOW_SAME_NAME=1
check "RC_ALLOW_SAME_NAME=1: the guard is lifted, launch"           bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
unset RC_ALLOW_SAME_NAME

reset; alive; fakeproc 4242 "$T/work" claude remote-control --name T1 --spawn same-dir
check "its own server is never a duplicate (ensure, code 0)"        exit_is 0 bash "$ENSURE" t1
check "its own server: ctl status shows no duplicate"               bash -c "! '$CTL' status t1 | grep -q 'DUPLICATE'"
fakeproc 5006 "$T/elsewhere" claude --remote-control T1
check "ctl status: shows the twin (pid and form)"                   bash -c "o=\$('$CTL' status t1); echo \"\$o\" | grep -q 'DUPLICATE' && echo \"\$o\" | grep -q 'pid 5006 (interactive)'"

echo "== memory guard"
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low"
check "available memory < 1024 MB: nothing is launched (code 8)"  exit_is 8 bash "$ENSURE" t1
check "low memory: tmux not called"                               test "$(n 'new-session')" = 0
check "low memory: logged with the figures"                       logged "available memory 488 MB"
check "low memory: the launch is not counted"                     test "$(grep -c . "$CLAUDE_RC_STATE_DIR/t1.launches" 2>/dev/null || true)" = 0
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low"; alive
check "low memory but session already running: nothing to do (code 0)" exit_is 0 bash "$ENSURE" t1
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low" RC_MIN_AVAILABLE_MB=100
check "lowered threshold (RC_MIN_AVAILABLE_MB=100): launch"       bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; export CLAUDE_RC_MEMINFO="$T/nonexistent"
check "unreadable meminfo: guard ignored, launch"                 bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"

echo "== lock (two simultaneous runs)"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; export STUB_TMUX_SLEEP=1
  for i in 1 2 3; do bash "$ENSURE" t1 >/dev/null 2>&1 & done; wait
  check "3 simultaneous runs: ONE SINGLE launch"                  test "$(n 'new-session')" = 1
  reset; export STUB_TMUX_BG=1 PPID_MARK=$$
  bash "$ENSURE" t1 >/dev/null 2>&1
  check "the lock is not inherited by tmux (free after the end)"  flock -n "$CLAUDE_RC_STATE_DIR/t1.lock" true
else skipped "lock: flock or Linux unavailable"; fi

echo "== claude-rc-run: resume and STRICT fallback according to the MESSAGE"
reset; export STUB_CONTINUE_RC=0; mkdir -p "$T/work"
check "--continue succeeds (code 0)"                              exit_is 0 bash "$RUN" t1
check "--continue succeeded: a single remote-control call"        test "$(n 'remote-control')" = 1
check "--continue succeeded: the call contains --continue"        test "$(n 'acceptEdits --continue')" = 1
check "--continue succeeded: the name and the mode are passed"    test "$(n 'remote-control --name T1 --permission-mode acceptEdits')" = 1
check "--continue succeeded: the instance is marked \"already started\"" test -e "$CLAUDE_RC_STATE_DIR/t1.started"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "$NOREC"
check "\"No recent session found\" + default (never): code 7"     exit_is 7 bash "$RUN" t1
check "never: NO new session (1 single call)"                     test "$(n 'remote-control')" = 1
check "never: logged with the fresh command to use"               logged "RC_FALLBACK=never.*claude-rc-ctl fresh t1 --yes"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "$NOREC"
check "\"No recent session found\" + norecord: fallback (code 0)" exit_is 0 bash "$RUN" t1
check "norecord: two remote-control calls"                        test "$(n 'remote-control')" = 2
check "norecord: the second call does NOT have --continue"        test "$(grep 'remote-control' "$STUB_LOG" | tail -1 | grep -c -- '--continue' || true)" = 0
check "norecord: logged (NEW session)"                            logged "NEW session"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord STUB_NET=ko; mkdir -p "$T/work"; screen "$NOREC"
check "norecord but network down: no fallback"                    bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"
check "network down: logged"                                      logged "unreachable"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "Error: Session session_x has no environment_id. It may never have been attached to a bridge."
check "\"has no environment_id\": code 6, NO new session"         bash -c "bash '$RUN' t1; [ \$? -eq 6 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"
reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: Session session_x has no environment_id. It may never have been attached to a bridge."
check "\"no environment_id\" even with norecord: no fallback"     bash -c "bash '$RUN' t1; [ \$? -eq 6 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Error: Session session_x is already being served by another \`claude remote-control\` instance (pid 4242) in /tmp/x. Use that terminal, or stop it first."
check "\"already being served\": code 5"                          exit_is 5 bash "$RUN" t1
check "\"already being served\": NO new session"                  test "$(n 'remote-control')" = 1
check "\"already being served\": logged as ERROR"                 logged "ERROR.*already being served"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: Another \`claude remote-control\` instance (pid 7) is already running in this directory. Exiting to avoid a split-brain conflict."
check "\"split-brain\" race: code 5, no new session"              bash -c "bash '$RUN' t1; [ \$? -eq 5 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Resuming session session_abc (16m ago)…"
check "resume under way then quick exit: NO new session"          bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: something unexpected (HTTP 503)"
check "unknown error: code 6"                                     exit_is 6 bash "$RUN" t1
check "unknown error: NO new session (even with norecord)"        test "$(n 'remote-control')" = 1
check "unknown error: the message is logged"                      logged "HTTP 503"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; : > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"
check "empty screen (no message): treated as unknown (6)"         exit_is 6 bash "$RUN" t1

reset; export STUB_CONTINUE_RC=1 STUB_CONTINUE_SLEEP=4 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "$NOREC"
check "failure AFTER a long time: never a fallback, even with this message" bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; mkdir -p "$T/work"
check "--fresh: a single call, without --continue"                bash -c "bash '$RUN' t1 --fresh; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ] && ! grep -q -- '--continue' '$STUB_LOG'"
check "--fresh: the instance is marked \"already started\""       test -e "$CLAUDE_RC_STATE_DIR/t1.started"
check "--fresh: passes --spawn same-dir (avoids the interactive question)" grep -q -- 'remote-control --name T1 --permission-mode acceptEdits --spawn same-dir' "$STUB_LOG"
reset; export STUB_CONTINUE_RC=0; mkdir -p "$T/work"; bash "$RUN" t1 >/dev/null 2>&1
check "--continue: does NOT pass --spawn"                         bash -c "! grep -q -- '--spawn' '$STUB_LOG'"

reset; mkdir -p "$T/work"; printf 'RC_NAME="Projet.ai/Démo  éà"\nRC_DIR="%s/w4"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t4.env"; mkdir -p "$T/w4"
check "free name passed unchanged to claude (spaces, \"/\", accents)" bash -c "bash '$RUN' t4 >/dev/null 2>&1; grep -qF 'remote-control --name Projet.ai/Démo  éà --permission-mode acceptEdits --continue' '$STUB_LOG'"

echo "== claude-rc-ctl: stop, resume, new session"
reset
check "ctl stop: creates the flag"                                bash -c "'$CTL' stop t1 >/dev/null 2>&1; test -e '$CLAUDE_RC_STATE_DIR/t1.stop'"
check "ctl status: shows the manual stop"                         bash -c "'$CTL' status t1 | grep -q 'manual stop        : YES'"
check "ensure after stop: nothing is launched"                    bash -c ": > '$STUB_LOG'; '$ENSURE' t1; test \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0"
check "ctl start: removes the flag and launches"                  bash -c "'$CTL' start t1 >/dev/null 2>&1; test ! -e '$CLAUDE_RC_STATE_DIR/t1.stop' && grep -q 'new-session' '$STUB_LOG'"
reset
check "ctl fresh without --yes: refused (code 64), nothing launched" bash -c "! '$CTL' fresh t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
reset
check "ctl fresh --yes: launches with --fresh"                    bash -c "'$CTL' fresh t1 --yes >/dev/null 2>&1; grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"
reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "ctl restart during an anti-loop pause: human decision, the counter restarts from zero and launches" bash -c "'$CTL' restart t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "ctl fresh --yes during an anti-loop pause: launches too"   bash -c "'$CTL' fresh t1 --yes >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; alive; export RC_STOP_WAIT=2
check "ctl stop: reports failure if the server does not disappear" exit_is 1 bash "$CTL" stop t1
reset; alive; export RC_STOP_WAIT=2
check "ctl restart: does NOT chain a launch if the old server survives" bash -c "! bash '$CTL' restart t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"

echo "== claude-rc-ctl: create / enable / disable / list"
reset; NOM="Name with  spaces / é'à"
check "create: writes the configuration and refuses to start anything" bash -c "'$CTL' create t5 --name \"$NOM\" --dir '$T/w5' >/dev/null 2>&1 && test -f '$CLAUDE_RC_CONFIG_DIR/t5.env' && [ \"\$(grep -c 'new-session\|systemctl' '$STUB_LOG' || true)\" = 0 ]"
check "create: the name (apostrophe, accents, double spaces) is read back identically" bash -c ". '$CLAUDE_RC_CONFIG_DIR/t5.env'; [ \"\$RC_NAME\" = \"$NOM\" ]"
check "create: working directory created"                         test -d "$T/w5"
check "create: acceptEdits mode and never fallback by default"    bash -c ". '$CLAUDE_RC_CONFIG_DIR/t5.env'; [ \"\$RC_PERMISSION_MODE\" = acceptEdits ] && [ \"\$RC_FALLBACK\" = never ]"
[ "$LINUX" = 1 ] && check "create: file is 600"                   test "$(mode_of "$CLAUDE_RC_CONFIG_DIR/t5.env")" = 600
check "create: refuses to overwrite an existing configuration"    bash -c "! '$CTL' create t5 --name X --dir '$T/w6' >/dev/null 2>&1"
check "create: name already taken -> refused (67) and nothing kept" bash -c "'$CTL' create t6 --name T1 --dir '$T/w6' >/dev/null 2>&1; [ \$? -eq 67 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create: temporary directory refused (69) and nothing kept" bash -c "env -u CLAUDE_RC_ALLOW_TMP '$CTL' create t6 --name X6 --dir /tmp/x6 >/dev/null 2>&1; [ \$? -eq 69 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create: bypassPermissions mode refused (65)"               bash -c "'$CTL' create t6 --name X6 --dir '$T/w6' --mode bypassPermissions >/dev/null 2>&1; [ \$? -eq 65 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create: without --name or --dir: refused (64)"             exit_is 64 bash "$CTL" create t6 --name X6
: > "$STUB_LOG"
check "enable before the first start: refused (64), systemctl not called" bash -c "'$CTL' enable t5 >/dev/null 2>&1; [ \$? -eq 64 ] && [ \"\$(grep -c systemctl '$STUB_LOG' || true)\" = 0 ]"
mkdir -p "$CLAUDE_RC_STATE_DIR"; date > "$CLAUDE_RC_STATE_DIR/t5.started"
check "enable after a first start: enables the timer"             bash -c "'$CTL' enable t5 >/dev/null 2>&1; grep -q 'systemctl --user enable --now claude-rc@t5.timer' '$STUB_LOG'"
check "disable: disables the timer without killing the session"   bash -c "'$CTL' disable t5 >/dev/null 2>&1; grep -q 'systemctl --user disable --now claude-rc@t5.timer' '$STUB_LOG' && ! grep -q 'kill' '$STUB_LOG'"
check "list: shows t1 and t5 with name and directory"             bash -c "o=\$('$CTL' list); echo \"\$o\" | grep -q '^t1 ' && echo \"\$o\" | grep -q '^t5 ' && echo \"\$o\" | grep -qF '$T/w5'"
alive
check "list: shows t1's running process"                          bash -c "'$CTL' list | grep '^t1 ' | grep -q 'pid 4242'"
check "list: shows the available memory"                          bash -c "'$CTL' list | grep -q 'available memory: 5859 MB'"

echo "== journal: rotation at maximum size"
reset
check "rotation: the journal becomes .log.1 above the cap"        bash -c ". '$ROOT/lib/common.sh'; RC_ID=t1; RC_LOG_MAX_BYTES=300; for i in \$(seq 1 20); do rc_log INFO \"line number \$i to fill the journal\"; done; rc_log INFO end; test -e '$CLAUDE_RC_STATE_DIR/t1.log.1'"
check "rotation: the current journal stays small"                 bash -c "test \"\$(stat -c %s '$CLAUDE_RC_STATE_DIR/t1.log')\" -lt 500"
check "rotation: a single generation is kept"                     bash -c "! ls '$CLAUDE_RC_STATE_DIR'/t1.log.2 >/dev/null 2>&1"
[ "$LINUX" = 1 ] && check "rotation: the journals stay 600"       bash -c "[ \"\$(stat -c %a '$CLAUDE_RC_STATE_DIR/t1.log')\" = 600 ] && [ \"\$(stat -c %a '$CLAUDE_RC_STATE_DIR/t1.log.1')\" = 600 ]"
check "default cap: 1 MB (1048576)"                               bash -c "grep -q 'RC_LOG_MAX_BYTES:-1048576' '$ROOT/lib/common.sh'"

echo "== permissions (umask 0002, as on the VPS)"
if [ "$LINUX" = 1 ]; then
  reset
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "state directory is 700"                                  test "$(mode_of "$CLAUDE_RC_STATE_DIR")" = 700
  check "journal is 600"                                          test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.log")" = 600
  check "state file (.last) is 600"                               test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.last")" = 600
  check "launch counter is 600"                                   test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.launches")" = 600
  check "the working directory keeps the normal umask (775)"      test "$(mode_of "$T/work")" = 775
else skipped "permissions: Linux required"; fi

echo "== lock and installation directories: permissions"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "lock created as 600 (umask 0002)"                        test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
  reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; ( umask 0002; : > "$CLAUDE_RC_STATE_DIR/t1.lock" ); chmod 664 "$CLAUDE_RC_STATE_DIR/t1.lock"
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "existing lock at 664: tightened to 600"                  test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
else skipped "lock permissions: Linux + flock required"; fi
if [ "$LINUX" = 1 ]; then
  H2="$T/home2"; mkdir -p "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.local/bin" "$H2/.config/systemd/user" "$H2/claude-rc/sessions"
  chmod 775 "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.config/systemd/user" "$H2/claude-rc" "$H2/claude-rc/sessions"; chmod 755 "$H2/.local/bin"
  ( umask 0002; HOME="$H2" XDG_CONFIG_HOME="$H2/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (existing directories at 775): ~/.config/claude-rc tightened to 700"   test "$(mode_of "$H2/.config/claude-rc")" = 700
  check "install (existing directories at 775): ~/.local/lib/claude-rc tightened to 700" test "$(mode_of "$H2/.local/lib/claude-rc")" = 700
  check "install (existing directories at 775): ~/claude-rc/sessions tightened to 700"  test "$(mode_of "$H2/claude-rc/sessions")" = 700
  check "install: ~/.local/bin (shared directory) UNCHANGED (755)"                    test "$(mode_of "$H2/.local/bin")" = 755
  check "install: ~/.config/systemd/user (shared directory) UNCHANGED (775)"          test "$(mode_of "$H2/.config/systemd/user")" = 775
  check "install: example configuration is 600"                                       test "$(mode_of "$H2/.config/claude-rc/session.env.example")" = 600
  check "install: NO session (no .env file) is created"                               bash -c "! ls '$H2/.config/claude-rc'/*.env >/dev/null 2>&1"
  check "install: units are 644 and scripts are 755"                                  bash -c "[ \"\$(stat -c %a '$H2/.config/systemd/user/claude-rc@.timer')\" = 644 ] && [ \"\$(stat -c %a '$H2/.local/lib/claude-rc/claude-rc-run')\" = 755 ]"
  H3="$T/home3"; mkdir -p "$H3"
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (new HOME, umask 0002): ~/.config/claude-rc created as 700"          test "$(mode_of "$H3/.config/claude-rc")" = 700
  check "install (new HOME, umask 0002): ~/.local/lib/claude-rc created as 700"       test "$(mode_of "$H3/.local/lib/claude-rc")" = 700
  check "install (new HOME): ~/claude-rc and ~/claude-rc/sessions created as 700"     bash -c "[ \"\$(stat -c %a '$H3/claude-rc')\" = 700 ] && [ \"\$(stat -c %a '$H3/claude-rc/sessions')\" = 700 ]"
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "reinstall: the directories stay 700"                                         bash -c "[ \"\$(stat -c %a '$H3/.config/claude-rc')\" = 700 ] && [ \"\$(stat -c %a '$H3/.local/lib/claude-rc')\" = 700 ]"
  reset; mkdir -p "$T/cfgex"; cp "$ROOT/conf/session.env.example" "$T/cfgex/example.env"
  check "the example configuration is valid once copied (simulated durable directory)" bash -c "HOME=/home/u CLAUDE_RC_CONFIG_DIR='$T/cfgex' env -u CLAUDE_RC_ALLOW_TMP bash -c '. \"$ROOT/lib/common.sh\"; rc_load_config example'"
else skipped "installation directory permissions: Linux required"; fi

echo "== process detection: pgrep -f pattern (tested on real command lines)"
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
matches() { printf '%s\n' "$1" | grep -Eq -- "$RC_SERVER_PATTERN"; }
check "recognises \"claude remote-control ...\""                  matches "claude remote-control --name X --permission-mode acceptEdits"
check "recognises claude's absolute path"                         matches "/home/u/.local/bin/claude remote-control --name X --continue"
check "recognises \"claude remote-control\" without options"      matches "claude remote-control"
check "recognises a name with spaces and accents"                 matches "claude remote-control --name Projet.ai/Démo  éà --permission-mode acceptEdits"
check "does not confuse it with the tmux process that contains it" bash -c "! printf '%s\n' 'tmux new-session -d -s rc claude remote-control --name X' | grep -Eq -- '$RC_SERVER_PATTERN'"
check "does not confuse it with another claude subcommand"        bash -c "! printf '%s\n' 'claude auth status' | grep -Eq -- '$RC_SERVER_PATTERN'"
check "does not confuse it with \"claude remote-controller\""     bash -c "! printf '%s\n' 'claude remote-controller' | grep -Eq -- '$RC_SERVER_PATTERN'"

echo "== installation"
check "install.sh --dry-run: code 0"                              exit_is 0 bash "$ROOT/install.sh" --dry-run
check "install.sh --dry-run: writes NOTHING"                      test ! -e "$T/home/.local" -a ! -e "$T/home/.config" -a ! -e "$T/home/claude-rc"
check "install.sh --dry-run: announces the units and the sessions" bash -c "'$ROOT/install.sh' --dry-run | grep -q 'claude-rc@.timer' && '$ROOT/install.sh' --dry-run | grep -q 'claude-rc/sessions'"
check "uninstall.sh --dry-run: code 0 and writes nothing"         bash -c "'$ROOT/uninstall.sh' --dry-run >/dev/null && test ! -e '$T/home/.local'"
check "install.sh / uninstall.sh: no kill, no tmux, no stop"      bash -c "! grep -nE '\\b(kill|pkill|tmux|restart)\\b|systemctl.* stop' '$ROOT/install.sh' '$ROOT/uninstall.sh'"
check "install.sh neither starts nor enables anything (no enable/start)" bash -c "! grep -nE 'systemctl.*(enable|start)' '$ROOT/install.sh'"

echo "== systemd units and hygiene"
S="$ROOT/systemd/user/claude-rc@.service"; M="$ROOT/systemd/user/claude-rc@.timer"
check "service: Type=oneshot"                                     grep -q '^Type=oneshot' "$S"
check "service: KillMode=process (tmux survives)"                 grep -q '^KillMode=process' "$S"
check "service: ExecStart points to claude-rc-ensure %i"          grep -q '^ExecStart=%h/.local/lib/claude-rc/claude-rc-ensure %i' "$S"
check "service: explicit PATH with ~/.local/bin"                  grep -q '^Environment=PATH=%h/.local/bin' "$S"
check "service: does not start without a configuration file"      grep -q '^ConditionPathExists=%E/claude-rc/%i.env' "$S"
check "service: no forced UMask (tmux and claude inherit the normal umask)" bash -c "! grep -q '^UMask=' '$S'"
check "timer: OnBootSec=60s"                                      grep -q '^OnBootSec=60s' "$M"
check "timer: OnUnitInactiveSec=60s"                              grep -q '^OnUnitInactiveSec=60s' "$M"
check "timer: AccuracySec=1s"                                     grep -q '^AccuracySec=1s' "$M"
check "timer: RandomizedDelaySec=30s (several sessions spread out)" grep -q '^RandomizedDelaySec=30s' "$M"
check "timer: WantedBy=timers.target"                             grep -q '^WantedBy=timers.target' "$M"
echo "== login check cache"
export CLAUDE_BIN="$STUBS/claude"
authcalls() { grep -c 'claude auth status' "$STUB_LOG" || true; }
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=1000
check "cache: 1st call, login OK"                                 exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache: 1st call = 1 real check"                            test "$(authcalls)" = 1
export CLAUDE_RC_NOW=1100
check "cache: 2nd call (100 s) still OK"                          exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache: 2nd call without a new check"                       test "$(authcalls)" = 1
export CLAUDE_RC_NOW=1400 STUB_AUTH=ko
check "cache: expired (400 s) + login lost = invalid"             exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache: expired = new check"                                test "$(authcalls)" = 2
check "cache: a failure clears the cache"                         test ! -e "$CLAUDE_RC_STATE_DIR/auth-ok"
export CLAUDE_RC_NOW=1401
check "cache: a failure is never remembered"                      exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache: so it is rechecked every time"                      test "$(authcalls)" = 3
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=2000
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"; export STUB_AUTH=ko CLAUDE_RC_NOW=2010
check "cache: RC_AUTH_FRESH=1 ignores the cache"                  exit_is 1 env RC_AUTH_FRESH=1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; export RC_AUTH_CACHE_SECONDS=0 CLAUDE_RC_NOW=3000
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok; rc_auth_ok"
check "cache: 0 = disabled (2 checks)"                            test "$(authcalls)" = 2
check "cache: 0 = no file written"                                test ! -e "$CLAUDE_RC_STATE_DIR/auth-ok"
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=100
mkdir -p "$CLAUDE_RC_STATE_DIR"; echo 5000 > "$CLAUDE_RC_STATE_DIR/auth-ok"
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache: timestamp in the future ignored"                    test "$(authcalls)" = 1
export RC_AUTH_CACHE_SECONDS=0; unset CLAUDE_RC_NOW STUB_AUTH
reset

echo "== login check: reading the file, without starting claude"
setcred() { mkdir -p "$T/cc"; printf '%s
' "$1" > "$T/cc/.credentials.json"; }
reset; setcred '{"claudeAiOauth":{"accessToken":"x","refreshToken":"y","expiresAt":1}}'
check "file with a refresh token: OK"                             exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "file with a token: claude is NOT started"                  test "$(authcalls)" = 0
export STUB_AUTH=ko
check "file with a token: OK even if the CLI would say no"        exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "RC_AUTH_FRESH=1 asks the CLI"                              exit_is 1 env RC_AUTH_FRESH=1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "RC_AUTH_MODE=cli asks the CLI"                             exit_is 1 env RC_AUTH_MODE=cli bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; setcred '{"claudeAiOauth":{"accessToken":"x"}}'
check "file without a refresh token: the CLI decides"             exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "file without a token: claude was indeed queried"           test "$(authcalls)" = 1
reset; setcred '{"claudeAiOauth":{"refreshToken":""}}'; export STUB_AUTH=ko
check "empty token: invalid login"                                exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; export STUB_AUTH=ko
check "file missing: the CLI decides (invalid)"                   exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset

for f in bin/claude-rc-ensure bin/claude-rc-run bin/claude-rc-ctl lib/common.sh install.sh uninstall.sh tests/run-tests.sh tests/hygiene.sh; do
  check "bash syntax: $f"                                         bash -n "$ROOT/$f"
done
echo "== repository hygiene before publishing (details: tests/hygiene.sh)"
check "hygiene: no key, IPv4, e-mail or long random string, nor any term from the personal list" bash "$ROOT/tests/hygiene.sh"
[ -f "$ROOT/tests/private-patterns.local" ] || skipped "personal list missing (tests/private-patterns.local): CREATE it before publishing"

echo
echo "Result: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]

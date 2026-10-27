#!/usr/bin/env bash
# claude-rc-keepalive: common functions. To be sourced, not executed.
# License: MIT (see LICENSE)
#
# Environment variables recognised (mostly for tests):
#   CLAUDE_RC_CONFIG_DIR    directory of the <id>.env files   (default: ~/.config/claude-rc)
#   CLAUDE_RC_STATE_DIR     journals, locks, flags            (default: ~/.local/state/claude-rc)
#   CLAUDE_RC_NOW           forced time in seconds
#   CLAUDE_RC_SCREEN_FILE   forced screen text (replaces `tmux capture-pane`)
#   CLAUDE_RC_PROC_ROOT     "/proc" root (tests)
#   CLAUDE_RC_MEMINFO       "meminfo" file (tests)
#   CLAUDE_RC_ALLOW_TMP=1   allows a temporary working directory (tests only)

: "${CLAUDE_RC_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-rc}"
: "${CLAUDE_RC_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/claude-rc}"

# Pattern (for pgrep -f / grep -E) of a `claude remote-control` server: "claude" (possibly with its path)
# as the first word, then "remote-control". Does NOT match the tmux or bash process that contains it.
RC_SERVER_PATTERN='^([^ ]*/)?claude remote-control( |$)'

rc_now() { if [ -n "${CLAUDE_RC_NOW:-}" ]; then echo "$CLAUDE_RC_NOW"; else date +%s; fi; }

# MONOTONIC clock (seconds) to measure durations: insensitive to system time corrections
# (common right after boot, when the clock is being set). rc_now stays the real time (anti-loop window).
rc_mono() { local up; if [ -r /proc/uptime ]; then read -r up _ < /proc/uptime; echo "${up%.*}"; else date +%s; fi; }

# Everything these scripts WRITE in the state directory is 600/700, whatever the user's umask.
# (The umask is NOT changed for the rest of the script: tmux and claude inherit the normal umask.)
rc_mkstate() { ( umask 077; mkdir -p "$CLAUDE_RC_STATE_DIR" ) && chmod 700 "$CLAUDE_RC_STATE_DIR" 2>/dev/null || true; }
rc_append()  { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s\n' "$*" >> "$f" ); }
rc_write()   { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s' "$*" > "$f" ); }

# rc_log LEVEL message...   -> one timestamped (UTC) line in <state>/<id>.log
# Rotation: above RC_LOG_MAX_BYTES (1 MB by default) the journal becomes <id>.log.1 (only one generation is kept).
rc_log() {
  local level=$1; shift
  local f="$CLAUDE_RC_STATE_DIR/${RC_ID:-claude-rc}.log" max=${RC_LOG_MAX_BYTES:-1048576} size
  rc_append "$f" "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [[ $size =~ ^[0-9]+$ ]] && [[ $max =~ ^[0-9]+$ ]] && [ "$size" -gt "$max" ]; then
    mv -f "$f" "$f.1" 2>/dev/null || true
  fi
}

# rc_note LEVEL STATE message...   -> logs only when the STATE changes (avoids one line per minute)
rc_note() {
  local level=$1 state=$2; shift 2
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.last"
  if [ "$(cat "$f" 2>/dev/null || true)" != "$state" ]; then
    rc_log "$level" "$*"
    rc_write "$f" "$state"
  fi
}

# Canonical path (symbolic links resolved); if that fails, the path as given.
rc_realdir() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }

# Single-quoted string, safe to write into a shell file (even with spaces, accents, apostrophes).
rc_squote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# A session name is free text (spaces, accents, "/", double spaces...) but: non-empty, no control
# character, no leading "-" (it would be taken for an option), at most 120 characters.
rc_valid_name() {
  local n=$1
  [ -n "$n" ] || return 1
  [ "${#n}" -le 120 ] || return 1
  case "$n" in -*) return 1 ;; esac
  [[ $n =~ [[:cntrl:]] ]] && return 1
  return 0
}

# A working directory must be absolute and durable: never /tmp, /var/tmp, /dev/shm, /run (emptied at boot).
rc_valid_dir() {
  local d=$1
  case "$d" in /*) ;; *) return 1 ;; esac
  [ "${CLAUDE_RC_ALLOW_TMP:-0}" = 1 ] && return 0
  case "$(rc_realdir "$d")" in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run|/run/*|/var/run|/var/run/*) return 1 ;;
  esac
  return 0
}

# rc_load_config ID -> loads <config>/<ID>.env and sets the RC_* variables.
# Codes: 64 invalid identifier, 65 permission mode refused, 66 configuration missing,
#        67 name or directory already used by another instance, 68 invalid session name,
#        69 working directory refused (relative or temporary), 70 invalid RC_FALLBACK,
#        71 invalid numeric setting.
rc_load_config() {
  RC_ID=${1:-}
  case "$RC_ID" in
    ''|*[!a-z0-9._-]*) echo "invalid identifier: '$RC_ID' (lowercase letters, digits, . _ - only)" >&2; return 64 ;;
  esac
  local f="$CLAUDE_RC_CONFIG_DIR/$RC_ID.env"
  [ -r "$f" ] || { echo "configuration not found: $f" >&2; return 66; }
  # The file is shell code: it belongs to the user and is never modified by these scripts.
  # shellcheck disable=SC1090
  . "$f"
  : "${RC_NAME:?RC_NAME missing in $f}"
  : "${RC_DIR:?RC_DIR missing in $f}"
  RC_DIR=${RC_DIR%/}
  RC_PERMISSION_MODE=${RC_PERMISSION_MODE:-acceptEdits}
  RC_FALLBACK=${RC_FALLBACK:-never}
  RC_ALLOW_SAME_NAME=${RC_ALLOW_SAME_NAME:-0}
  CLAUDE_BIN=${CLAUDE_BIN:-$HOME/.local/bin/claude}
  RC_TMUX_SESSION=${RC_TMUX_SESSION:-rc-$RC_ID}
  RC_CONTINUE_FAIL_SECONDS=${RC_CONTINUE_FAIL_SECONDS:-45}
  RC_MAX_LAUNCHES=${RC_MAX_LAUNCHES:-3}
  RC_LAUNCH_WINDOW=${RC_LAUNCH_WINDOW:-600}
  RC_STOP_WAIT=${RC_STOP_WAIT:-20}
  RC_MIN_AVAILABLE_MB=${RC_MIN_AVAILABLE_MB:-1024}
  RC_LOG_MAX_BYTES=${RC_LOG_MAX_BYTES:-1048576}
  rc_valid_name "$RC_NAME" || { echo "invalid RC_NAME: '$RC_NAME' (1 to 120 characters, no control character, must not start with \"-\")" >&2; return 68; }
  rc_valid_dir "$RC_DIR" || { echo "RC_DIR refused: '$RC_DIR' (absolute and durable path required; never /tmp, /var/tmp, /dev/shm, /run)" >&2; return 69; }
  # Deliberately short allow-list: never bypassPermissions, nor dontAsk, nor auto.
  case "$RC_PERMISSION_MODE" in
    default|acceptEdits|plan) ;;
    *) echo "permission mode refused: '$RC_PERMISSION_MODE' (allowed: default, acceptEdits, plan)" >&2; return 65 ;;
  esac
  case "$RC_FALLBACK" in
    never|norecord) ;;
    *) echo "invalid RC_FALLBACK: '$RC_FALLBACK' (never or norecord)" >&2; return 70 ;;
  esac
  local v
  for v in "$RC_CONTINUE_FAIL_SECONDS" "$RC_MAX_LAUNCHES" "$RC_LAUNCH_WINDOW" "$RC_STOP_WAIT" "$RC_MIN_AVAILABLE_MB" "$RC_LOG_MAX_BYTES"; do
    [[ $v =~ ^[0-9]+$ ]] || { echo "invalid numeric setting: '$v'" >&2; return 71; }
  done
  RC_STOP_FLAG="$CLAUDE_RC_STATE_DIR/$RC_ID.stop"
  RC_LAUNCHES="$CLAUDE_RC_STATE_DIR/$RC_ID.launches"
  RC_STARTED="$CLAUDE_RC_STATE_DIR/$RC_ID.started"
  rc_check_unique "$f" || return 67
  return 0
}

# Two instances must share NEITHER the name NOR the directory: --continue is tied to the directory, and a server
# refuses to start where another one runs; sharing would resume or double the wrong session.
rc_check_unique() {
  local self=$1 other o_name o_dir mydir
  mydir=$(rc_realdir "$RC_DIR")
  for other in "$CLAUDE_RC_CONFIG_DIR"/*.env; do
    [ -e "$other" ] && [ "$other" != "$self" ] || continue
    o_name=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_NAME:-}" )
    o_dir=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_DIR:-}" )
    o_dir=$(rc_realdir "${o_dir%/}")
    if [ "$o_name" = "$RC_NAME" ]; then echo "RC_NAME '$RC_NAME' already used by $(basename "$other")" >&2; return 1; fi
    if [ "$o_dir" = "$mydir" ]; then echo "RC_DIR '$RC_DIR' already used by $(basename "$other")" >&2; return 1; fi
  done
  return 0
}

rc_escape_ere() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# PID(s) of the current user's `claude remote-control` server THAT WORKS IN RC_DIR.
# Detection is by the process's WORKING DIRECTORY (/proc/<pid>/cwd), not by its name: the name can contain
# anything (spaces, accents...) and two sessions never share a directory. A session started by hand
# in the same directory is thus "adopted" instead of being doubled.
rc_server_pids() {
  local proc=${CLAUDE_RC_PROC_ROOT:-/proc} want pid cwd
  want=$(rc_realdir "$RC_DIR")
  for pid in $(pgrep -u "$(id -u)" -f "$RC_SERVER_PATTERN" 2>/dev/null); do
    cwd=$(readlink -f -- "$proc/$pid/cwd" 2>/dev/null) || continue
    [ "$cwd" = "$want" ] && echo "$pid"
  done
  return 0
}

# Remote Control sessions of the user, WHATEVER their launch method (read from /proc):
#   server       claude remote-control --name <NAME> ...   (those of claude-rc-keepalive, or started by hand)
#   interactive  claude --remote-control <NAME> ...        (for example in a tmux window, outside claude-rc-keepalive)
# One line per process: "pid<TAB>form<TAB>directory<TAB>name". Arguments are read NUL-separated: a name
# with spaces or accents is therefore read correctly. An ordinary `claude --name ...` (no Remote Control) is not counted.
rc_named_sessions() {
  local proc=${CLAUDE_RC_PROC_ROOT:-/proc} d pid cwd form name i
  local -a args
  for d in "$proc"/[0-9]*; do
    [ -O "$d" ] && [ -r "$d/cmdline" ] || continue
    args=()
    mapfile -d '' -t args < "$d/cmdline" 2>/dev/null || continue
    [ "${#args[@]}" -ge 2 ] && [ "${args[0]##*/}" = claude ] || continue
    form=""; name=""
    if [ "${args[1]}" = remote-control ]; then
      for ((i = 2; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
          --name)   form=server; name=${args[i+1]-}; break ;;
          --name=*) form=server; name=${args[i]#--name=}; break ;;
        esac
      done
    else
      for ((i = 1; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
          --remote-control)   form=interactive; name=${args[i+1]-}; break ;;
          --remote-control=*) form=interactive; name=${args[i]#--remote-control=}; break ;;
        esac
      done
    fi
    [ -n "$form" ] && [ -n "$name" ] && [ "${name:0:1}" != "-" ] || continue
    pid=${d##*/}
    cwd=$(readlink -f -- "$d/cwd" 2>/dev/null) || cwd="?"
    printf '%s\t%s\t%s\t%s\n' "$pid" "$form" "$cwd" "$name"
  done
}

# Names used by SEVERAL processes: "name<TAB>pid<TAB>form<TAB>directory", grouped by name.
rc_duplicate_names() {
  rc_named_sessions | awk -F'\t' '
    { n[$4]++; row[NR] = $4 "\t" $1 "\t" $2 "\t" $3; nm[NR] = $4 }
    END { for (i = 1; i <= NR; i++) if (n[nm[i]] > 1) print row[i] }' | sort -t$'\t' -k1,1 -k2,2n
}

# Processes that use the name of THIS instance (RC_NAME) without being one of its own servers (those in
# RC_DIR): "pid<TAB>form<TAB>directory". Launching one more server would create a duplicate.
rc_name_conflicts() {
  local own pid form cwd name
  own=" $(rc_server_pids | tr '\n' ' ') "
  while IFS=$'\t' read -r pid form cwd name; do
    [ "$name" = "$RC_NAME" ] || continue
    case "$own" in *" $pid "*) continue ;; esac
    printf '%s\t%s\t%s\n' "$pid" "$form" "$cwd"
  done < <(rc_named_sessions)
}

# Memory actually available (MB), from /proc/meminfo; empty if unreadable.
rc_mem_available_mb() {
  local f=${CLAUDE_RC_MEMINFO:-/proc/meminfo} kb
  kb=$(awk '/^MemAvailable:/ {print $2; exit}' "$f" 2>/dev/null)
  [[ $kb =~ ^[0-9]+$ ]] && echo $((kb / 1024))
  return 0
}

# Resident memory (KB) of a process and all its descendants.
rc_tree_rss_kb() {
  ps -eo pid=,ppid=,rss= 2>/dev/null | awk -v root="$1" '
    { p[$1] = $2; r[$1] = $3 }
    END { tot = 0
          for (i in p) { x = i; n = 0
            while (x != "" && x != 0 && n++ < 64) { if (x == root) { tot += r[i]; break }; x = p[x] } }
          print tot }'
}

# Anthropic API reachable? (any HTTP answer is enough; only a network/DNS/TLS failure fails)
rc_network_ok() { curl -sS -o /dev/null -m 8 --connect-timeout 5 https://api.anthropic.com/ >/dev/null 2>&1; }

# Valid Claude login? (claude auth status prints JSON with "loggedIn": true)
# A POSITIVE result is remembered for RC_AUTH_CACHE_SECONDS (default 300; 0 = no cache) in a file common to all
# instances: N instances no longer make N calls per minute. A negative result is never remembered (and clears the cache).
# RC_AUTH_FRESH=1 forces a real check (used by `claude-rc-ctl status`).
rc_auth_ok() {
  local f="$CLAUDE_RC_STATE_DIR/auth-ok" ttl=${RC_AUTH_CACHE_SECONDS:-300} now ts=""
  case "$ttl" in ''|*[!0-9]*) ttl=300 ;; esac
  now=$(rc_now)
  # "file" mode (default): the credentials file is READ without starting claude. Running `claude auth status` can
  # trigger a token refresh, racing with the sessions' own: that is what caused the loss of the login.
  if [ "${RC_AUTH_MODE:-file}" = file ] && [ "${RC_AUTH_FRESH:-0}" != 1 ]      && grep -Eqs '"refreshToken"[[:space:]]*:[[:space:]]*"[^"]+"' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"; then
    return 0
  fi
  if [ "$ttl" -gt 0 ] && [ "${RC_AUTH_FRESH:-0}" != 1 ] && [ -r "$f" ]; then
    read -r ts < "$f" 2>/dev/null || ts=""
    case "$ts" in ''|*[!0-9]*) ts="" ;; esac
    if [ -n "$ts" ] && [ "$ts" -le "$now" ] && [ $((now - ts)) -lt "$ttl" ]; then return 0; fi
  fi
  if "$CLAUDE_BIN" auth status 2>/dev/null | grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    if [ "$ttl" -gt 0 ]; then rc_mkstate; ( umask 077; printf '%s
' "$now" > "$f.$$" && mv -f "$f.$$" "$f" ) 2>/dev/null || true; fi
    return 0
  fi
  rm -f "$f" 2>/dev/null
  return 1
}

# Non-blocking per-instance lock: prevents two simultaneous runs (timer + manual command)
# from each launching a session. Without `flock` (util-linux), no lock.
# File descriptor 9 must NOT be inherited by tmux: the launch is done with "9>&-".
rc_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  rc_mkstate
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.lock"
  ( umask 077; : >> "$f" ) 2>/dev/null   # created as 600 if it does not exist...
  chmod 600 "$f" 2>/dev/null || true      # ...and tightened if it already existed with wider permissions
  exec 9>>"$f" || return 0
  flock -n 9
}

# Text of the current tmux pane's screen (claude's error messages are displayed there).
rc_screen() {
  if [ -n "${CLAUDE_RC_SCREEN_FILE:-}" ]; then cat "$CLAUDE_RC_SCREEN_FILE" 2>/dev/null; return 0; fi
  [ -n "${TMUX_PANE:-}" ] && tmux capture-pane -p -J -S -200 -t "$TMUX_PANE" 2>/dev/null
  return 0
}

# Anti-loop guard: at most RC_MAX_LAUNCHES launches per sliding window of RC_LAUNCH_WINDOW seconds.
# Beyond that, a pause (code 4); it lifts by itself when the oldest launches leave the window.
rc_launch_allowed() {
  local now cutoff kept=0 t tmp
  now=$(rc_now); cutoff=$((now - RC_LAUNCH_WINDOW))
  rc_mkstate
  [ -f "$RC_LAUNCHES" ] || ( umask 077; : > "$RC_LAUNCHES" )
  tmp=$( umask 077; mktemp "$RC_LAUNCHES.XXXXXX" )
  while read -r t; do
    if [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge "$cutoff" ]; then echo "$t" >> "$tmp"; kept=$((kept + 1)); fi
  done < "$RC_LAUNCHES"
  mv "$tmp" "$RC_LAUNCHES"
  [ "$kept" -lt "$RC_MAX_LAUNCHES" ]
}
rc_record_launch() { rc_append "$RC_LAUNCHES" "$(rc_now)"; }

# Marks "this instance has already started at least once": `claude-rc-ctl enable` requires it (otherwise the first
# session must first be created explicitly with `claude-rc-ctl fresh <id> --yes`).
rc_mark_started() { rc_write "$RC_STARTED" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; }

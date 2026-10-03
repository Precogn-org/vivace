# Changelog

## Unreleased

- **Fewer login checks.** A successful `claude auth status` is remembered for `RC_AUTH_CACHE_SECONDS` (default 300,
  `0` disables) in one file shared by all instances, so N instances no longer make N calls per minute. A failure is
  never remembered. Side effect: a login that drops is noticed after at most that delay instead of one minute.
- **Duplicate sessions are now detected and refused.** Until now only the instances of this tool were checked against
  each other; a Remote Control session started any other way (for example `claude --remote-control <name>` in a tmux
  window, or a server started by hand in another folder) was invisible, so the same name could run twice, each with its
  own conversation and its own memory. Now:
  - `claude-rc-ctl list` reports every Remote Control process of the user that shares a name (both launch forms, pid,
    folder); `claude-rc-ctl status <id>` shows the twin(s) of that instance;
  - `claude-rc-ensure` does not launch a server when another process already carries the instance's name: exit **9**,
    logged with the pids. `RC_ALLOW_SAME_NAME=1` in the instance file lifts the guard.
  Names are read from NUL-separated arguments, so names with spaces or accents are handled.

## 2.2.0 — 2026-09-26

Behaviour changes (please read):

- **No silent new session.** `RC_FALLBACK=never` (default): "No recent session found" now stops with exit code 7 instead
  of creating a new session. `RC_FALLBACK=norecord` restores the previous behaviour, for that message only.
  "No environment_id" no longer creates a new session either (exit 6). A first session is created explicitly with
  `claude-rc-ctl fresh <id> --yes`.
- **`install.sh` no longer creates a `test-vps-cli.env`.** It creates no session at all; it installs
  `conf/session.env.example` and the durable folder `~/claude-rc/sessions/` (700).
- Working directories under `/tmp`, `/var/tmp`, `/dev/shm`, `/run` and relative paths are refused (exit 69).
- New sessions are launched with `--spawn same-dir` (avoids an interactive question that blocks unattended starts).

New:

- Free session names (spaces, accents, `/`, double spaces; 1-120 characters, no control character, no leading `-`).
- The running server is detected by its **working directory** (`/proc/<pid>/cwd`) instead of its name.
- `claude-rc-ctl create | enable | disable | list`; `status` shows the memory of the server and its children.
- Memory guard: nothing is launched below `RC_MIN_AVAILABLE_MB` of available memory (exit 8).
- Journal rotation at 1 MB (`<id>.log.1`).
- Timer jitter raised to 30 s for several instances.
- `start`, `restart`, `fresh` reset the anti-loop counter (human decisions).
- About 170 automated checks (fake `claude`, `tmux`, `curl`, `pgrep`, `systemctl`, fake `/proc`).

## 2.1

Locks (`flock`), private state files (600/700), message-based decisions for `--continue` failures, monotonic clock,
verified real restart and reboot.

# claude-rc-keepalive

> **Product name: Vivace.** This repository (`claude-rc-keepalive`) is the engine behind **Vivace** — it keeps Claude Code agents always-on and pilotable in remote live.

🇬🇧 English · 🇫🇷 [Français](README.fr.md)

Keeps **Claude Code Remote Control sessions** alive on an always-on Linux machine (VPS, mini-PC): each one is restarted
after a stop or a reboot and, whenever possible, **resumes the same claude.ai session**, so you can keep driving it from
your phone, tablet or claude.ai/code. One instance = one session = one working directory.

> **Status: v2.2, tested with one real session** (Claude Code 2.1.282, Ubuntu 24.04): real crash, timer resume, restart,
> anti-loop pause and automatic resume; the reboot resume was verified on the previous version (v2.1). Several points are
> still unverified (the ~4-hour resume window, late network at boot…): see [docs/VERIFIED.md](docs/VERIFIED.md).
> Not affiliated with, or endorsed by, Anthropic.
> Note: the scripts' log messages and code comments are currently in French; the documentation is bilingual.
> Changes: [CHANGELOG.md](CHANGELOG.md).

## Why

`claude remote-control` is a **local** process: if it stops (reboot, long network outage, crash), the session goes
"offline" and nothing brings it back. The official documentation recommends `tmux` or `screen` on a remote machine but
describes neither automatic start nor supervision. This repository provides a minimal answer: a few shell scripts and two
**user-level** systemd units (no administrator rights needed).

## How it works

```
   machine boot ─(60 s)─┐                every minute ─┐
                         ▼                              ▼
                 claude-rc@<id>.timer ───────► claude-rc@<id>.service (oneshot, ~1 s)
                                                          │  claude-rc-ensure <id>
                                                          ▼
        another check already running? ─yes─► let it finish        (flock lock)
        deliberate stop requested?     ─yes─► do nothing           (flag file <id>.stop)
        server already in this folder? ─yes─► check the Claude login (a hand-started session is ADOPTED)
        another process, same name?    ─yes─► log it, exit 9       (never create a twin, whatever way the other one was started)
        Anthropic API reachable?       ─no──► wait                 (never create a session "by mistake" because of the network)
        Claude login valid?            ─no──► log it, exit 3
        too many recent launches?      ─yes─► pause, exit 4        (resumes by itself)
        enough free memory?            ─no──► log it, exit 8       (nothing is launched)
                 │
                 ▼
        tmux new-session ─► claude-rc-run <id>
                                 └─ claude remote-control --name … --continue                (same claude.ai session)
                                         │ on failure the MESSAGE decides (the exit code is always 1)
                                         ├─ "No recent session found" ─► RC_FALLBACK=never (default): nothing, exit 7
                                         │                               RC_FALLBACK=norecord: NEW session (only in this case)
                                         ├─ "already being served / already running" ─► nothing (duplicate avoided)
                                         └─ any other message                        ─► nothing (human decision)
```

Why read the message: `--continue` exits with code 1 both when there is **nothing to resume** and when **the session
is already being served** by another process. Treating every failure as "create a new session" would create duplicates.
**A new session is never created silently**: only `claude-rc-ctl fresh <id> --yes` (explicit) or `RC_FALLBACK=norecord`
(explicitly enabled, and only for the "No recent session found" message) can do it. All known messages are listed in
[docs/VERIFIED.md](docs/VERIFIED.md).

**Server detection is by working directory, not by name**: an instance owns a folder, and a `claude remote-control`
process whose current directory (`/proc/<pid>/cwd`) is that folder is "its" server. Session names are therefore free
(spaces, accents, `/`, double spaces…).

## Requirements

- Linux with **systemd** (user manager), `tmux`, `curl`, `bash`, `pgrep`, `flock` (util-linux; without it there is no lock).
- [Claude Code](https://code.claude.com/docs/en/quickstart) installed and **signed in** (`claude auth login`, claude.ai
  account: Pro, Max, Team or Enterprise; API keys do not work with Remote Control).
- `loginctl enable-linger <user>` (check with `loginctl show-user $USER -p Linger` → `Linger=yes`), otherwise the timer
  only starts at the first login.
- Each working directory already **trusted** by Claude Code (the "trust" dialog: run `claude` there once).

## Layout

In the repository:

```
bin/claude-rc-ensure      checks / restarts (called by the timer)
bin/claude-rc-run         runs inside tmux: --continue, then, depending on the message and RC_FALLBACK, a new session
bin/claude-rc-ctl         list | create | enable | disable | status | start | stop | restart | fresh | logs | screen
lib/common.sh             shared functions
systemd/user/claude-rc@.service   template unit (oneshot, KillMode=process)
systemd/user/claude-rc@.timer     template timer (60 s after boot, then every minute, spread by up to 30 s)
conf/session.env.example          example configuration for one session
install.sh / uninstall.sh         (--dry-run available)
tests/run-tests.sh                automated tests with fake claude/tmux/curl/pgrep/systemctl and fake /proc
tests/hygiene.sh                  pre-publication scan (keys, IPv4, e-mails, personal terms)
docs/VERIFIED.md                  verified / unverified, Claude Code messages
```

Created by `install.sh` (inside the user's home directory only):

| Path | Mode | Purpose |
|---|---|---|
| `~/.local/lib/claude-rc/` (4 files) | directory **700**, scripts 755, `common.sh` 644 | scripts |
| `~/.local/bin/claude-rc-ctl` | symlink | command |
| `~/.config/systemd/user/claude-rc@.service`, `claude-rc@.timer` | 644 | units |
| `~/.config/claude-rc/` and `session.env.example` | directory **700**, file **600** (never overwritten) | configuration (one `<id>.env` per session) |
| `~/claude-rc/sessions/` | directory **700** | durable working directories for sessions that have no project folder |

Created at run time, **all 600 in a 700 directory**: `~/.local/state/claude-rc/<id>.{log,log.1,last,launches,started,stop,lock}`.
Shared directories (`~/.local/bin`, `~/.config/systemd/user`) are never modified. **`install.sh` creates no session and
starts nothing.**

## Install

```bash
./install.sh --dry-run          # prints everything it would do, writes nothing
./install.sh                    # copies files; creates no session, starts NOTHING
```

## Create a session

```bash
claude-rc-ctl create my-project --name "My project / v2" --dir ~/projects/my-project
claude-rc-ctl fresh  my-project --yes    # first session, requested explicitly
claude-rc-ctl enable my-project          # automatic start (resume with --continue) from now on
claude-rc-ctl list
```

- `create` validates and writes `~/.config/claude-rc/my-project.env` (mode 600); it starts nothing.
- `fresh --yes` creates the claude.ai session. It passes `--spawn same-dir` because a **new** session otherwise asks an
  interactive question ("Spawn mode? [1/2]") the first time in a folder, which would block an unattended start.
- `enable` refuses until the instance has started at least once (otherwise the first launch would find "nothing to resume").
- A session **already started by hand** in the same folder is **adopted**: the timer sees it alive and leaves it alone; it
  only takes over the next time it stops.
- Working directories must be **absolute and durable**: `/tmp`, `/var/tmp`, `/dev/shm` and `/run` are refused (emptied at boot).
  Two instances cannot share the same name or folder.

## Uninstall

```bash
./uninstall.sh --dry-run
./uninstall.sh                  # removes units and scripts; running sessions are NOT stopped
./uninstall.sh --purge          # also removes configuration and logs
```

## Day-to-day use

```bash
claude-rc-ctl list                       # every session: name, folder, timer, process, memory
claude-rc-ctl status  <id>               # state, memory, Claude login, last journal lines
claude-rc-ctl stop    <id>               # DELIBERATE stop: the timer will not restart it until you run start
claude-rc-ctl start   <id>               # clears the deliberate stop and launches (resume with --continue)
claude-rc-ctl restart <id>               # stops the process (and waits until it is gone), restarts with --continue
claude-rc-ctl fresh   <id> --yes         # NEW session (the old one stays offline in claude.ai: archive it)
claude-rc-ctl disable <id>               # switches the timer off; the running session is NOT stopped
claude-rc-ctl logs    <id> 100           # journal
claude-rc-ctl screen  <id>               # current screen of the session (read-only)
tmux attach -t rc-<id>                   # watch/drive the session in a terminal (Ctrl-b d to leave)
```

`start`, `restart` and `fresh` are human decisions: they also reset the anti-loop counter.

## Making sessions talk to each other

Each kept-alive instance is an independent `claude remote-control` process: nothing here makes them aware of one
another. If a session tries to reach a peer with **`mcp__ccd_session_mgmt__send_message`** — the tool used by
sessions the Claude Code Desktop app itself launched or tracks — it will usually fail to reach a standalone
`claude remote-control` instance, because that registry only knows about sessions the app manages.

There is a **separate, native `SendMessage` / `ListAgents` pair**, independent of the Desktop app, that does reach
these instances (tested and confirmed on 2.1.283, in both directions, verified directly in the recipient's own
transcript — not just a `success: true` response). If a session needs to message another kept-alive instance, tell
it to use the native `SendMessage` tool, not `ccd_session_mgmt`. See
[anthropics/claude-code#89938](https://github.com/anthropics/claude-code/issues/89938) for background: cross-session
messaging through the app-tracked path has a known, currently open delivery bug on this exact setup (long-lived
`claude remote-control --spawn=same-dir` sessions in tmux); the native path was not affected in our testing.

## Configuration (`~/.config/claude-rc/<id>.env`)

Shell syntax, **no secret**. See [conf/session.env.example](conf/session.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `RC_NAME` | (required) | name shown in claude.ai/code and the mobile app; free text (1-120 characters, no control character, not starting with `-`) |
| `RC_DIR` | (required) | absolute, durable working directory, unique per instance |
| `RC_PERMISSION_MODE` | `acceptEdits` | `default`, `acceptEdits` or `plan` (**`bypassPermissions`, `auto`, `dontAsk` are refused**) |
| `RC_FALLBACK` | `never` | `never`: no new session, ever, unless you ask; `norecord`: new session only on "No recent session found" |
| `RC_MIN_AVAILABLE_MB` | `1024` | do not launch when `MemAvailable` is lower (exit 8) |
| `RC_ALLOW_SAME_NAME` | `0` | `1` lifts the duplicate-name guard (exit 9): only if two processes with the same name are really wanted |
| `RC_AUTH_CACHE_SECONDS` | `300` | A successful `claude auth status` is remembered this long, in one file shared by all instances (fewer calls per minute). `0` disables. A failure is never remembered; `claude-rc-ctl status` always checks for real |
| `RC_MAX_LAUNCHES` / `RC_LAUNCH_WINDOW` | `3` / `600` | anti-loop: at most N launches per M seconds, then an automatic pause |
| `RC_LOG_MAX_BYTES` | `1048576` | journal rotation: `<id>.log` becomes `<id>.log.1` (one generation kept) |
| `RC_CONTINUE_FAIL_SECONDS` | `45` | a `--continue` failure before this delay is analysed (message read from the screen) |

## Exit codes

`claude-rc-ensure`:

| Code | Meaning |
|---|---|
| 0 | all good (running, launched, deliberate stop, network absent, or a check is already running) |
| 1 | tmux failed to start / working directory could not be created |
| 3 | Claude login invalid: nothing is launched (the service shows as "failed") |
| 4 | anti-loop pause (3 launches within 10 minutes); **resumes by itself** when the window has elapsed |
| 8 | not enough free memory (`RC_MIN_AVAILABLE_MB`): nothing is launched |
| 9 | another process already carries the same session name (a twin, started any other way, e.g. `claude --remote-control <name>` in a tmux window): nothing is launched |
| 64-71 | invalid configuration: 64 identifier, 65 permission mode, 66 missing, 67 name/folder already taken, 68 invalid name, 69 relative or temporary folder, 70 invalid `RC_FALLBACK`, 71 invalid number |

`claude-rc-run`: claude's own exit code, or **5** (session already served by another instance), **6** (unknown failure of
`--continue`, or session never attached), **7** (nothing to resume and `RC_FALLBACK=never`).

## What happens when…

- **the machine reboots**: the user manager starts (thanks to linger) and each timer fires about 60 s after boot (plus up
  to 30 s of jitter). If the network is not up yet, the script waits and retries every minute without launching anything.
- **`--continue` succeeds** (stopped for less than about 4 h, session still known to the server): **same claude.ai
  session**, same conversation. The server is then in "single session" mode; when the session ends, it exits and the timer
  picks it up again a minute later.
- **nothing to resume** ("No recent session found", e.g. after more than 4 h): **no new session** with the default
  `RC_FALLBACK=never` (exit 7, logged with the command to run); with `norecord`, a new session with the same name. The old
  one stays "offline" in claude.ai/code: archive it.
- **the session is already being served** by another process: **no new session**, exit 5.
- **unknown error** (network, server…): **no new session**, exit 6, the message is logged; the timer retries (at most 3
  launches per 10 minutes). If the session is definitely lost: `claude-rc-ctl fresh <id> --yes`.
- **the Claude login expires**: nothing is launched, a clear error is logged and the service fails
  (`systemctl --user --failed`). Run `claude auth login` again.
- **free memory is low**: nothing new is launched (exit 8); sessions already running are untouched.
- **several instances**: each has its own `<id>.env`, tmux session (`rc-<id>`), journal, lock and counter.

## Working directory, `CLAUDE.md` and access to other folders

- Claude Code loads the `CLAUDE.md` of every parent of the working directory: a session started in a subfolder of a
  repository gets the repository's `CLAUDE.md` **and** `~/CLAUDE.md` (verified).
- Under `acceptEdits`, a session writes without asking **only inside its working directory and its additional
  directories**; reading or writing elsewhere is refused (headless) or prompts (interactive). `claude remote-control` has
  **no `--add-dir` option**: declare the folders in a settings file instead —
  `~/.claude/settings.json` (every session of the user) or `<working dir>/.claude/settings.local.json` (one folder):
  ```json
  { "permissions": { "additionalDirectories": ["/home/me/projects"] } }
  ```
  Verified: without it, writing to a sibling project was denied; with it, reading and writing worked (see
  [docs/VERIFIED.md](docs/VERIFIED.md)). Beware that `<dir>/.claude/` may be tracked by git: check your `.gitignore`.
- The `CLAUDE.md` of an additional directory is only loaded when `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` (set to `1`).

## Security

- No administrator rights, no open port: Remote Control only makes **outbound** connections.
- No secret in this repository nor in the configuration files; the login is the one from `claude auth login`
  (`~/.claude/.credentials.json`, mode 600): these scripts **never read that file** and only call `claude auth status`.
- Allowed permission modes: `default`, `acceptEdits`, `plan`. **`bypassPermissions`, `auto` and `dontAsk` are refused** by the
  script. A remotely driven session can run commands on the machine with the rights of the account: choose the working
  directory, the additional directories and the account accordingly.
- `<id>.env` is loaded as shell code: it must belong to the user and be writable only by them (600).
- State files are 600 in a 700 directory, whatever the `umask`. The normal `umask` is kept for tmux and claude.

## Known limitations

- **One instance = one working directory = one session name**, all unique (`--continue` is tied to the directory).
  Two instances in nested folders (one in a subfolder of the other) are distinct for this tool, but this has not been
  tested with two real servers.
- After a resume the server is in **"single session"** mode: no new sessions from the phone.
- With `KillMode=process`, tmux and claude stay in the finished service's cgroup, and systemd logs "Found left-over
  process … Ignoring" warnings at each pass. Harmless, but noisy; a cleaner design is planned.
- Memory: about **370 MB** per idle session (server + child), measured once; a working session uses more. Nothing limits
  the number of instances except `RC_MIN_AVAILABLE_MB`: size your machine (and swap) accordingly.
- Linux only (`/proc`, `flock`, GNU `stat`/`readlink`).
- The ~4-hour resume window and a reboot with a late network are **not verified**.

## Tests

```bash
bash tests/run-tests.sh          # on Linux (or WSL); about 170 checks
```

The tests use fake `claude`, `tmux`, `curl`, `pgrep` and `systemctl`, and a fake `/proc`: they touch neither the network
nor a real session. They do not replace a real test (see [docs/VERIFIED.md](docs/VERIFIED.md)). On Windows (Git Bash),
the permission and lock tests are skipped.

**Before publishing a fork or a contribution:** `bash tests/hygiene.sh` scans for keys, IPv4 addresses, e-mail addresses and
long random strings. To add your own terms that must never be published (names, projects, hosts), create
`tests/private-patterns.local` (one pattern per line). That file is in `.gitignore` and must **never** be committed.

## License

MIT (see [LICENSE](LICENSE)).

#!/usr/bin/env bash
# Installs claude-rc-keepalive for the current user (no administrator rights).
# Does NOT enable or START ANYTHING: no session is created (see `claude-rc-ctl create`).
#
# Usage: ./install.sh [--dry-run]
#   --dry-run   prints exactly what would be done, without writing anything
set -euo pipefail

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  '') ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

SRC=$(cd "$(dirname "$0")" && pwd)
CFG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
LIB="$HOME/.local/lib/claude-rc"
BIN="$HOME/.local/bin"
CONF="$CFG_HOME/claude-rc"
UNITS="$CFG_HOME/systemd/user"
SESSIONS="$HOME/claude-rc/sessions"

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

echo "Installing claude-rc-keepalive (dry-run=$DRY)"
run mkdir -p "$BIN" "$UNITS"                # SHARED directories: never modified (created only if missing)
run mkdir -p -m 700 "$LIB" "$CONF" "$HOME/claude-rc" "$SESSIONS"   # OUR directories: private (700)...
run chmod 700 "$LIB" "$CONF" "$HOME/claude-rc" "$SESSIONS"         # ...even if they already existed with wider permissions (reinstall)
for f in claude-rc-ensure claude-rc-run claude-rc-ctl; do run install -m 755 "$SRC/bin/$f" "$LIB/$f"; done
run install -m 644 "$SRC/lib/common.sh" "$LIB/common.sh"
run ln -sf "$LIB/claude-rc-ctl" "$BIN/claude-rc-ctl"
for u in claude-rc@.service claude-rc@.timer; do run install -m 644 "$SRC/systemd/user/$u" "$UNITS/$u"; done

# Example configuration (never active: only *.env files are sessions). Never overwritten.
if [ -e "$CONF/session.env.example" ]; then
  echo "  existing example kept: $CONF/session.env.example"
else
  run install -m 600 "$SRC/conf/session.env.example" "$CONF/session.env.example"
fi
run systemctl --user daemon-reload

cat <<MSG

Files installed. NO session exists, NOTHING is started or enabled.
Create a session (example):
  claude-rc-ctl create my-project --name "Display name" --dir $SESSIONS/my-project
  claude-rc-ctl fresh  my-project --yes      # first session, requested explicitly
  claude-rc-ctl enable my-project            # automatic start (resume with --continue)
  claude-rc-ctl list
Uninstall: ./uninstall.sh   (running sessions are NOT stopped)
MSG

#!/usr/bin/env bash
# Uninstalls claude-rc-keepalive. The RUNNING Remote Control session is NOT stopped
# (KillMode=process): it keeps going until it is stopped or the machine next reboots.
#
# Usage: ./uninstall.sh [--dry-run] [--purge]
#   --dry-run   prints what would be done, without doing anything
#   --purge     also deletes the configurations (~/.config/claude-rc) and journals (~/.local/state/claude-rc)
set -uo pipefail

DRY=0; PURGE=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --purge) PURGE=1 ;;
    *) echo "usage: $0 [--dry-run] [--purge]" >&2; exit 64 ;;
  esac
done

CFG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
LIB="$HOME/.local/lib/claude-rc"
CONF="$CFG_HOME/claude-rc"
UNITS="$CFG_HOME/systemd/user"

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@" || true; fi; }

echo "Uninstalling claude-rc-keepalive (dry-run=$DRY, purge=$PURGE)"
# Disables every instantiated timer (one per configuration file).
if [ -d "$CONF" ]; then
  for f in "$CONF"/*.env; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .env)
    run systemctl --user disable --now "claude-rc@${id}.timer"
  done
fi
run rm -f "$UNITS/claude-rc@.service" "$UNITS/claude-rc@.timer"
run rm -f "$HOME/.local/bin/claude-rc-ctl"
run rm -rf "$LIB"
run systemctl --user daemon-reload
if [ "$PURGE" = 1 ]; then
  run rm -rf "$CONF" "$STATE_HOME/claude-rc"
else
  echo "  configurations and journals kept ($CONF, $STATE_HOME/claude-rc); use --purge to delete them"
fi

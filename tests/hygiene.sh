#!/usr/bin/env bash
# Scan BEFORE PUBLISHING: no personal data or secret may be present in the repository.
# Exit code: 0 = nothing found, 1 = something was found (printed), 2 = usage error.
# Usage: bash tests/hygiene.sh [directory]      (default: the repository root)
#
# GENERIC patterns only: no real name, e-mail or address may appear in this public file.
# This file and run-tests.sh are excluded from the generic scans (they contain the patterns themselves).
# PERSONAL terms: one pattern per line in tests/private-patterns.local (NOT versioned, see .gitignore);
# that scan covers ALL files, tests included.
set -uo pipefail

ROOT=$(cd "${1:-$(dirname "$0")/..}" && pwd) || exit 2
EXCL=(--exclude=hygiene.sh --exclude=run-tests.sh --exclude-dir=.git)
fail=0; scans=0

found() {   # found "label" "results"
  echo "  FOUND   $1"; printf '%s\n' "$2" | head -12 | cut -c1-200 | sed 's/^/          /'; fail=1
}
ok() { echo "  clean   $1"; }
scan() {    # scan "label" regex
  local hits; scans=$((scans + 1))
  if hits=$(grep -RInE "$2" "$ROOT" "${EXCL[@]}" 2>/dev/null) && [ -n "$hits" ]; then found "$1" "$hits"; else ok "$1"; fi
}

scan "keys and tokens in known formats" \
  'sk-[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{20,}|cfut_|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-|BEGIN [A-Z ]*PRIVATE KEY'
scan "IPv4 addresses" \
  '([0-9]{1,3}\.){3}[0-9]{1,3}'

scans=$((scans + 1))
hits=$(grep -RInE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$ROOT" "${EXCL[@]}" 2>/dev/null | grep -v 'claude-rc@' || true)
if [ -n "$hits" ]; then found "e-mail addresses (except the systemd templates claude-rc@…)" "$hits"; else ok "e-mail addresses (except the systemd templates claude-rc@…)"; fi

scans=$((scans + 1))
hits=$(grep -RInoE '[A-Za-z0-9+_=-]{32,}' "$ROOT" "${EXCL[@]}" 2>/dev/null | awk -F: '{t=$3; if (t ~ /[0-9]/ && t ~ /[A-Za-z]/) print}' || true)
if [ -n "$hits" ]; then found "long random strings (>= 32 characters with letters and digits)" "$hits"; else ok "long random strings (>= 32 characters with letters and digits)"; fi

PRIV="$ROOT/tests/private-patterns.local"
if [ -f "$PRIV" ]; then
  scans=$((scans + 1))
  if hits=$(grep -RInEf "$PRIV" "$ROOT" --exclude=private-patterns.local --exclude-dir=.git 2>/dev/null) && [ -n "$hits" ]; then
    found "terms from tests/private-patterns.local" "$hits"
  else ok "terms from tests/private-patterns.local"; fi
else
  echo "  skipped personal list missing (tests/private-patterns.local): CREATE it before publishing"
fi

echo "hygiene: $scans scan(s), $([ "$fail" = 0 ] && echo 'nothing found' || echo 'PROBLEM(S) FOUND')"
exit "$fail"

#!/usr/bin/env bash
# Balayage AVANT PUBLICATION : aucune donnée personnelle ni secret ne doit se trouver dans le dépôt.
# Code de sortie : 0 = rien trouvé, 1 = quelque chose a été trouvé (affiché), 2 = erreur d'utilisation.
# Usage : bash tests/hygiene.sh [dossier]      (défaut : la racine du dépôt)
#
# Motifs GÉNÉRIQUES uniquement : aucun nom, e-mail ou adresse réels ne doit figurer dans ce fichier public.
# Ce fichier et run-tests.sh sont exclus des balayages génériques (ils contiennent les motifs eux-mêmes).
# Termes PERSONNELS : un motif par ligne dans tests/private-patterns.local (NON versionné, voir .gitignore) ;
# ce balayage-là couvre TOUS les fichiers, tests compris.
set -uo pipefail

ROOT=$(cd "${1:-$(dirname "$0")/..}" && pwd) || exit 2
EXCL=(--exclude=hygiene.sh --exclude=run-tests.sh --exclude-dir=.git)
fail=0; scans=0

found() {   # found "libellé" "résultats"
  echo "  TROUVÉ  $1"; printf '%s\n' "$2" | head -12 | cut -c1-200 | sed 's/^/          /'; fail=1
}
ok() { echo "  propre  $1"; }
scan() {    # scan "libellé" regex
  local hits; scans=$((scans + 1))
  if hits=$(grep -RInE "$2" "$ROOT" "${EXCL[@]}" 2>/dev/null) && [ -n "$hits" ]; then found "$1" "$hits"; else ok "$1"; fi
}

scan "clés et jetons aux formats connus" \
  'sk-[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{20,}|cfut_|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-|BEGIN [A-Z ]*PRIVATE KEY'
scan "adresses IPv4" \
  '([0-9]{1,3}\.){3}[0-9]{1,3}'

scans=$((scans + 1))
hits=$(grep -RInE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$ROOT" "${EXCL[@]}" 2>/dev/null | grep -v 'claude-rc@' || true)
if [ -n "$hits" ]; then found "adresses e-mail (hors modèles systemd claude-rc@…)" "$hits"; else ok "adresses e-mail (hors modèles systemd claude-rc@…)"; fi

scans=$((scans + 1))
hits=$(grep -RInoE '[A-Za-z0-9+_=-]{32,}' "$ROOT" "${EXCL[@]}" 2>/dev/null | awk -F: '{t=$3; if (t ~ /[0-9]/ && t ~ /[A-Za-z]/) print}' || true)
if [ -n "$hits" ]; then found "longues chaînes aléatoires (>= 32 caractères avec lettres et chiffres)" "$hits"; else ok "longues chaînes aléatoires (>= 32 caractères avec lettres et chiffres)"; fi

PRIV="$ROOT/tests/private-patterns.local"
if [ -f "$PRIV" ]; then
  scans=$((scans + 1))
  if hits=$(grep -RInEf "$PRIV" "$ROOT" --exclude=private-patterns.local --exclude-dir=.git 2>/dev/null) && [ -n "$hits" ]; then
    found "termes de tests/private-patterns.local" "$hits"
  else ok "termes de tests/private-patterns.local"; fi
else
  echo "  ignoré  liste personnelle absente (tests/private-patterns.local) : À CRÉER avant de publier"
fi

echo "hygiène : $scans balayage(s), $([ "$fail" = 0 ] && echo 'rien trouvé' || echo 'PROBLÈME(S) TROUVÉ(S)')"
exit "$fail"

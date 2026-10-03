#!/usr/bin/env bash
# Essais automatiques de claude-rc-keepalive. AUCUN vrai claude, tmux, curl, pgrep ni systemctl n'est appelé :
# de faux exécutables (« stubs ») sont placés en tête du PATH, dans un dossier temporaire supprimé à la fin ;
# /proc et /proc/meminfo sont remplacés par de faux fichiers (CLAUDE_RC_PROC_ROOT, CLAUDE_RC_MEMINFO).
# À lancer sous Linux (ou WSL) : quelques essais (droits de fichiers, verrou flock) sont ignorés ailleurs.
# Usage : bash tests/run-tests.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'pkill -f "claude-rc-test-bg-$$" 2>/dev/null; rm -rf "$T"' EXIT
STUBS="$T/stubs"; mkdir -p "$STUBS" "$T/home" "$T/config"
LINUX=0; [ "$(uname -s)" = Linux ] && LINUX=1

export HOME="$T/home"
export CLAUDE_RC_CONFIG_DIR="$T/config" CLAUDE_RC_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" SCREEN="$T/screen.txt"
export CLAUDE_RC_PROC_ROOT="$T/proc" CLAUDE_RC_MEMINFO="$T/meminfo" CLAUDE_RC_ALLOW_TMP=1 RC_AUTH_CACHE_SECONDS=0 CLAUDE_CONFIG_DIR="$T/cc"   # (dossiers de test sous /tmp)
export PATH="$STUBS:$PATH"
printf 'MemTotal: 8000000 kB\nMemAvailable: 6000000 kB\n' > "$T/meminfo"
printf 'MemTotal: 8000000 kB\nMemAvailable: 500000 kB\n' > "$T/meminfo.low"

# ---------- faux exécutables ----------
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

# ---------- configuration de test ----------
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
check() { local name=$1; shift; if "$@"; then echo "  ok     $name"; pass=$((pass + 1)); else echo "  ECHEC  $name"; fail=$((fail + 1)); fi; }
skipped() { echo "  ignoré $1"; skip=$((skip + 1)); }
reset() { rm -rf "$CLAUDE_RC_STATE_DIR" "$T/work" "$T/proc"; : > "$STUB_LOG"; rm -f "$SCREEN"
          for x in t2 t3 t4 t5 t6 exemple; do rm -f "$CLAUDE_RC_CONFIG_DIR/$x.env"; done
          export CLAUDE_RC_MEMINFO="$T/meminfo" CLAUDE_RC_ALLOW_TMP=1
          unset STUB_AUTH STUB_NET STUB_ALIVE STUB_PID STUB_CONTINUE_RC STUB_CONTINUE_SLEEP STUB_FRESH_RC STUB_TMUX_HAS STUB_TMUX_SLEEP STUB_TMUX_BG CLAUDE_RC_NOW CLAUDE_RC_SCREEN_FILE RC_FORCE_FRESH RC_STOP_WAIT RC_FALLBACK RC_MIN_AVAILABLE_MB RC_LOG_MAX_BYTES RC_ALLOW_SAME_NAME RC_AUTH_FRESH RC_AUTH_MODE; rm -rf "$T/cc"; }
# alive [dossier] : un faux serveur (pid 4242) travaille dans ce dossier (défaut : celui de t1)
alive() { export STUB_ALIVE=1; rm -rf "$T/proc"; mkdir -p "$T/proc/4242"; ln -sfn "${1:-$T/work}" "$T/proc/4242/cwd"; }
n() { grep -c -- "$1" "$STUB_LOG" || true; }               # nombre d'appels contenant le motif
logged() { grep -q -- "$1" "$CLAUDE_RC_STATE_DIR/t1.log" 2>/dev/null; }
exit_is() { local want=$1; shift; "$@" >/dev/null 2>&1; [ $? -eq "$want" ]; }
screen() { printf '%s\n' "$1" > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"; }
NOREC='Error: No recent session found in this directory or its worktrees. Run `claude remote-control` to start a new one.'
mode_of() { stat -c %a "$1"; }

echo "== configuration"
reset
cp "$T/bypass.env" "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "mode bypassPermissions refusé (code 65)"                   exit_is 65 bash "$ENSURE" bypass
rm -f "$CLAUDE_RC_CONFIG_DIR/bypass.env"
check "identifiant invalide refusé (code 64)"                     exit_is 64 bash "$ENSURE" "Bad ID"
check "configuration absente (code 66)"                           exit_is 66 bash "$ENSURE" inconnu
printf 'RC_NAME="T1"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom déjà utilisé par une autre instance (code 67)"         exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/work/"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "dossier déjà utilisé (même avec « / » final) (code 67)"    exit_is 67 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "deux instances aux noms et dossiers distincts : acceptées" exit_is 0 bash "$ENSURE" t2
rm -f "$CLAUDE_RC_CONFIG_DIR/t2.env"

echo "== noms de session libres, dossiers durables, réglages"
reset
printf 'RC_NAME="Projet.ai/Démo  éà - test"\nRC_DIR="%s/w2"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom avec espaces, « / », accents et double espace : accepté" exit_is 0 bash "$ENSURE" t2
printf 'RC_NAME="-option"\nRC_DIR="%s/w2"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom commençant par « - » refusé (code 68)"                 exit_is 68 bash "$ENSURE" t2
{ printf 'RC_NAME=$'"'"'a\\nb'"'"'\nRC_DIR="%s/w2"\n' "$T"; } > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom avec saut de ligne refusé (code 68)"                   exit_is 68 bash "$ENSURE" t2
printf 'RC_NAME="%s"\nRC_DIR="%s/w2"\n' "$(printf 'x%.0s' $(seq 121))" "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "nom de plus de 120 caractères refusé (code 68)"            exit_is 68 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="relatif/w2"\n' > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "dossier relatif refusé (code 69)"                          exit_is 69 bash "$ENSURE" t2
for d in /tmp/x /var/tmp/x /dev/shm/x /run/x; do
  printf 'RC_NAME="T2"\nRC_DIR="%s"\n' "$d" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
  check "dossier temporaire $d refusé (code 69)"                  bash -c "env -u CLAUDE_RC_ALLOW_TMP bash '$ENSURE' t2 >/dev/null 2>&1; [ \$? -eq 69 ]"
done
printf 'RC_NAME="T2"\nRC_DIR="/home/u/claude-rc/sessions/t2"\n' > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "dossier durable (hors /tmp) accepté par la validation"     bash -c "env -u CLAUDE_RC_ALLOW_TMP bash -c '. \"$ROOT/lib/common.sh\"; rc_valid_dir /home/u/claude-rc/sessions/t2'"
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nRC_FALLBACK="toujours"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "RC_FALLBACK invalide refusé (code 70)"                     exit_is 70 bash "$ENSURE" t2
printf 'RC_NAME="T2"\nRC_DIR="%s/w2"\nRC_MAX_LAUNCHES="beaucoup"\n' "$T" > "$CLAUDE_RC_CONFIG_DIR/t2.env"
check "réglage numérique invalide refusé (code 71)"               exit_is 71 bash "$ENSURE" t2
rm -f "$CLAUDE_RC_CONFIG_DIR/t2.env"

echo "== claude-rc-ensure : décisions"
reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; date > "$CLAUDE_RC_STATE_DIR/t1.stop"
check "arrêt volontaire : rien n'est lancé (code 0)"              exit_is 0 bash "$ENSURE" t1
check "arrêt volontaire : tmux non appelé"                        test "$(n 'new-session')" = 0
check "arrêt volontaire : journalisé"                             logged "arrêt volontaire actif"

reset; alive
check "session déjà en cours, connexion OK (code 0)"              exit_is 0 bash "$ENSURE" t1
check "session en cours : aucun doublon lancé"                    test "$(n 'new-session')" = 0
check "session en cours : journalisé"                             logged "en cours"
check "session en cours (adoptée) : marquée « déjà démarrée »"    test -e "$CLAUDE_RC_STATE_DIR/t1.started"
reset; alive; export STUB_AUTH=ko
check "session en cours mais connexion invalide (code 3)"         exit_is 3 bash "$ENSURE" t1

reset; export STUB_NET=ko
check "réseau coupé : pas de lancement, code 0"                   exit_is 0 bash "$ENSURE" t1
check "réseau coupé : tmux non appelé"                            test "$(n 'new-session')" = 0
check "réseau coupé : journalisé"                                 logged "injoignable"

reset; export STUB_AUTH=ko
check "connexion invalide : rien n'est lancé (code 3)"            exit_is 3 bash "$ENSURE" t1
check "connexion invalide : tmux non appelé"                      test "$(n 'new-session')" = 0

reset
check "cas nominal : lancement (code 0)"                          exit_is 0 bash "$ENSURE" t1
check "lancement : tmux new-session -s rc-t1"                     test "$(n 'new-session -d -s rc-t1')" = 1
check "lancement : exécute claude-rc-run (sans --fresh)"          test "$(n 'claude-rc-run t1$')" = 1
check "lancement : dossier de travail créé"                       test -d "$T/work"
check "lancement : 1 entrée dans le compteur anti-boucle"         test "$(grep -c . "$CLAUDE_RC_STATE_DIR/t1.launches")" = 1

reset; export RC_FORCE_FRESH=1
check "RC_FORCE_FRESH=1 : le lancement porte --fresh"             bash -c "bash '$ENSURE' t1 && grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"

reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "anti-boucle : 3 lancements en 10 min -> pause (code 4)"    exit_is 4 bash "$ENSURE" t1
check "anti-boucle : tmux non appelé"                             test "$(n 'new-session')" = 0
export CLAUDE_RC_NOW=1600
check "anti-boucle : 10 min plus tard -> reprise AUTOMATIQUE"     exit_is 0 bash "$ENSURE" t1
check "anti-boucle : lancement effectif"                          test "$(n 'new-session')" = 1

echo "== détection d'un serveur existant par son DOSSIER de travail"
reset; alive; printf 'RC_NAME="Tout autre nom"\nRC_DIR="%s/work"\n' "$T" > "$T/autre.env"
check "serveur dans le même dossier (nom différent) : adopté, pas de doublon" bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
reset; alive "$T/ailleurs"
check "serveur d'un AUTRE dossier (nom illisible) : ignoré (lancement)" bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; alive "$T/work/sous-dossier"
check "serveur dans un SOUS-dossier : distinct (lancement)"       bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; mkdir -p "$T/reel" "$T/work"; rmdir "$T/work"; ln -sfn "$T/reel" "$T/work"; alive "$T/reel"
check "dossier configuré via un lien symbolique : reconnu"        bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
rm -f "$T/work"; rm -rf "$T/reel"
reset; alive
check "ctl status : affiche le pid et la mémoire du serveur"      bash -c "'$CTL' status t1 | grep -q 'processus serveur  : en cours (pid 4242)'"
check "ctl status : affiche le repli (fallback) never par défaut" bash -c "'$CTL' status t1 | grep -q 'repli (fallback)   : never'"

echo "== doublons de noms (toutes méthodes de lancement)"
# fakeproc <pid> <dossier> <argument...> : un faux processus (ligne de commande séparée par NUL + dossier de travail)
fakeproc() { local pid=$1 cwd=$2; shift 2; mkdir -p "$T/proc/$pid" "$cwd"; ln -sfn "$cwd" "$T/proc/$pid/cwd"; printf '%s\0' "$@" > "$T/proc/$pid/cmdline"; }
NOM="Nom avec espaces é"

reset; fakeproc 5001 "$T/a" claude remote-control --name "Alpha" --spawn same-dir
check "list : un nom unique -> aucun avertissement"                 bash -c "! '$CTL' list | grep -q 'DOUBLONS'"

reset; fakeproc 5001 "$T/a" /usr/bin/claude remote-control --name "$NOM" --spawn same-dir
fakeproc 5002 "$T/b" /home/x/.local/bin/claude --remote-control "$NOM" --model opus
check "list : même nom, formes serveur et interactive -> DOUBLONS"  bash -c "'$CTL' list | grep -q 'DOUBLONS'"
check "list : le nom avec espaces et accent est lu en entier"       bash -c "'$CTL' list | grep -qF '« $NOM »'"
check "list : les deux pid et les deux formes sont montrés"         bash -c "o=\$('$CTL' list); echo \"\$o\" | grep -q 'pid 5001 .*serveur' && echo \"\$o\" | grep -q 'pid 5002 .*interactive'"
check "list : code de sortie 0 malgré les doublons"                 exit_is 0 "$CTL" list

reset; fakeproc 5001 "$T/a" claude remote-control --name "Alpha"
fakeproc 5003 "$T/c" claude --name "Alpha" --model opus
fakeproc 5004 "$T/d" claude --remote-control --model opus
fakeproc 5005 "$T/e" bash -c "claude --remote-control Alpha"
check "list : « claude --name » ordinaire, --remote-control sans nom et autre programme ne comptent pas" bash -c "! '$CTL' list | grep -q 'DOUBLONS'"

reset; fakeproc 5006 "$T/ailleurs" claude --remote-control T1 --model opus
check "ensure : un AUTRE processus porte le nom -> rien n'est lancé (code 9)" exit_is 9 bash "$ENSURE" t1
check "ensure : doublon -> tmux non appelé"                         test "$(n 'new-session')" = 0
check "ensure : doublon -> journalisé avec le pid et le dossier"    logged "porte déjà le nom « T1 » : pid 5006 (interactive, $T/ailleurs)"
check "ensure : doublon -> le lancement n'est pas compté"           bash -c "! test -s '$CLAUDE_RC_STATE_DIR/t1.launches'"

reset; fakeproc 5007 "$T/ailleurs" claude remote-control --name T1 --spawn same-dir
check "ensure : un serveur de même nom dans un autre dossier -> refusé (code 9)" exit_is 9 bash "$ENSURE" t1

reset; fakeproc 5006 "$T/ailleurs" claude --remote-control T1; export RC_ALLOW_SAME_NAME=1
check "RC_ALLOW_SAME_NAME=1 : le garde-fou est levé, lancement"     bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
unset RC_ALLOW_SAME_NAME

reset; alive; fakeproc 4242 "$T/work" claude remote-control --name T1 --spawn same-dir
check "son propre serveur n'est jamais un doublon (ensure, code 0)" exit_is 0 bash "$ENSURE" t1
check "son propre serveur : ctl status n'affiche pas de doublon"    bash -c "! '$CTL' status t1 | grep -q 'DOUBLON'"
fakeproc 5006 "$T/ailleurs" claude --remote-control T1
check "ctl status : montre le jumeau (pid et forme)"                bash -c "o=\$('$CTL' status t1); echo \"\$o\" | grep -q 'DOUBLON' && echo \"\$o\" | grep -q 'pid 5006 (interactive)'"

echo "== garde-fou mémoire"
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low"
check "mémoire disponible < 1024 Mo : rien n'est lancé (code 8)"  exit_is 8 bash "$ENSURE" t1
check "mémoire basse : tmux non appelé"                           test "$(n 'new-session')" = 0
check "mémoire basse : journalisé avec les chiffres"              logged "mémoire disponible 488 Mo"
check "mémoire basse : le lancement n'est pas compté"             test "$(grep -c . "$CLAUDE_RC_STATE_DIR/t1.launches" 2>/dev/null || true)" = 0
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low"; alive
check "mémoire basse mais session déjà en cours : rien à faire (code 0)" exit_is 0 bash "$ENSURE" t1
reset; export CLAUDE_RC_MEMINFO="$T/meminfo.low" RC_MIN_AVAILABLE_MB=100
check "seuil abaissé (RC_MIN_AVAILABLE_MB=100) : lancement"       bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; export CLAUDE_RC_MEMINFO="$T/inexistant"
check "meminfo illisible : garde-fou ignoré, lancement"           bash -c "bash '$ENSURE' t1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"

echo "== verrou (deux exécutions simultanées)"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; export STUB_TMUX_SLEEP=1
  for i in 1 2 3; do bash "$ENSURE" t1 >/dev/null 2>&1 & done; wait
  check "3 exécutions simultanées : UN SEUL lancement"            test "$(n 'new-session')" = 1
  reset; export STUB_TMUX_BG=1 PPID_MARK=$$
  bash "$ENSURE" t1 >/dev/null 2>&1
  check "le verrou n'est pas hérité par tmux (libre après la fin)" flock -n "$CLAUDE_RC_STATE_DIR/t1.lock" true
else skipped "verrou : flock ou Linux indisponible"; fi

echo "== claude-rc-run : reprise et repli STRICT selon le MESSAGE"
reset; export STUB_CONTINUE_RC=0; mkdir -p "$T/work"
check "--continue réussit (code 0)"                               exit_is 0 bash "$RUN" t1
check "--continue réussi : un seul appel remote-control"          test "$(n 'remote-control')" = 1
check "--continue réussi : l'appel contient --continue"           test "$(n 'acceptEdits --continue')" = 1
check "--continue réussi : le nom et le mode sont transmis"       test "$(n 'remote-control --name T1 --permission-mode acceptEdits')" = 1
check "--continue réussi : l'instance est marquée « déjà démarrée »" test -e "$CLAUDE_RC_STATE_DIR/t1.started"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "$NOREC"
check "« No recent session found » + défaut (never) : code 7"     exit_is 7 bash "$RUN" t1
check "never : AUCUNE nouvelle session (1 seul appel)"            test "$(n 'remote-control')" = 1
check "never : journalisé avec la commande fresh à utiliser"      logged "RC_FALLBACK=never.*claude-rc-ctl fresh t1 --yes"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "$NOREC"
check "« No recent session found » + norecord : repli (code 0)"   exit_is 0 bash "$RUN" t1
check "norecord : deux appels remote-control"                     test "$(n 'remote-control')" = 2
check "norecord : le second appel n'a PAS --continue"             test "$(grep 'remote-control' "$STUB_LOG" | tail -1 | grep -c -- '--continue' || true)" = 0
check "norecord : journalisé (NOUVELLE session)"                  logged "NOUVELLE session"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord STUB_NET=ko; mkdir -p "$T/work"; screen "$NOREC"
check "norecord mais réseau coupé : pas de repli"                 bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"
check "réseau coupé : journalisé"                                 logged "injoignable"

reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0; mkdir -p "$T/work"; screen "Error: Session session_x has no environment_id. It may never have been attached to a bridge."
check "« has no environment_id » : code 6, AUCUNE nouvelle session" bash -c "bash '$RUN' t1; [ \$? -eq 6 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"
reset; export STUB_CONTINUE_RC=1 STUB_FRESH_RC=0 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: Session session_x has no environment_id. It may never have been attached to a bridge."
check "« no environment_id » même avec norecord : aucun repli"    bash -c "bash '$RUN' t1; [ \$? -eq 6 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1; mkdir -p "$T/work"; screen "Error: Session session_x is already being served by another \`claude remote-control\` instance (pid 4242) in /tmp/x. Use that terminal, or stop it first."
check "« already being served » : code 5"                         exit_is 5 bash "$RUN" t1
check "« already being served » : AUCUNE nouvelle session"        test "$(n 'remote-control')" = 1
check "« already being served » : journalisé en ERROR"            logged "ERROR.*déjà servie"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: Another \`claude remote-control\` instance (pid 7) is already running in this directory. Exiting to avoid a split-brain conflict."
check "course « split-brain » : code 5, aucune nouvelle session"  bash -c "bash '$RUN' t1; [ \$? -eq 5 ] && [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Resuming session session_abc (16m ago)…"
check "reprise engagée puis arrêt rapide : PAS de nouvelle session" bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "Error: quelque chose d'imprévu (HTTP 503)"
check "erreur inconnue : code 6"                                  exit_is 6 bash "$RUN" t1
check "erreur inconnue : AUCUNE nouvelle session (même avec norecord)" test "$(n 'remote-control')" = 1
check "erreur inconnue : le message est journalisé"               logged "HTTP 503"

reset; export STUB_CONTINUE_RC=1 RC_FALLBACK=norecord; mkdir -p "$T/work"; : > "$SCREEN"; export CLAUDE_RC_SCREEN_FILE="$SCREEN"
check "écran vide (pas de message) : traité comme inconnu (6)"    exit_is 6 bash "$RUN" t1

reset; export STUB_CONTINUE_RC=1 STUB_CONTINUE_SLEEP=4 RC_FALLBACK=norecord; mkdir -p "$T/work"; screen "$NOREC"
check "échec APRÈS longtemps : jamais de repli, même avec ce message" bash -c "bash '$RUN' t1; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ]"

reset; mkdir -p "$T/work"
check "--fresh : un seul appel, sans --continue"                  bash -c "bash '$RUN' t1 --fresh; [ \"\$(grep -c 'remote-control' '$STUB_LOG')\" = 1 ] && ! grep -q -- '--continue' '$STUB_LOG'"
check "--fresh : l'instance est marquée « déjà démarrée »"        test -e "$CLAUDE_RC_STATE_DIR/t1.started"
check "--fresh : transmet --spawn same-dir (évite la question interactive)" grep -q -- 'remote-control --name T1 --permission-mode acceptEdits --spawn same-dir' "$STUB_LOG"
reset; export STUB_CONTINUE_RC=0; mkdir -p "$T/work"; bash "$RUN" t1 >/dev/null 2>&1
check "--continue : ne transmet PAS --spawn"                      bash -c "! grep -q -- '--spawn' '$STUB_LOG'"

reset; mkdir -p "$T/work"; printf 'RC_NAME="Projet.ai/Démo  éà"\nRC_DIR="%s/w4"\nCLAUDE_BIN="%s/claude"\n' "$T" "$STUBS" > "$CLAUDE_RC_CONFIG_DIR/t4.env"; mkdir -p "$T/w4"
check "nom libre transmis tel quel à claude (espaces, « / », accents)" bash -c "bash '$RUN' t4 >/dev/null 2>&1; grep -qF 'remote-control --name Projet.ai/Démo  éà --permission-mode acceptEdits --continue' '$STUB_LOG'"

echo "== claude-rc-ctl : arrêt, reprise, nouvelle session"
reset
check "ctl stop : crée le drapeau"                                bash -c "'$CTL' stop t1 >/dev/null 2>&1; test -e '$CLAUDE_RC_STATE_DIR/t1.stop'"
check "ctl status : affiche l'arrêt volontaire"                   bash -c "'$CTL' status t1 | grep -q 'arrêt volontaire   : OUI'"
check "ensure après stop : rien n'est lancé"                      bash -c ": > '$STUB_LOG'; '$ENSURE' t1; test \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0"
check "ctl start : retire le drapeau et lance"                    bash -c "'$CTL' start t1 >/dev/null 2>&1; test ! -e '$CLAUDE_RC_STATE_DIR/t1.stop' && grep -q 'new-session' '$STUB_LOG'"
reset
check "ctl fresh sans --yes : refusé (code 64), rien lancé"       bash -c "! '$CTL' fresh t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"
reset
check "ctl fresh --yes : lance avec --fresh"                      bash -c "'$CTL' fresh t1 --yes >/dev/null 2>&1; grep -q 'claude-rc-run t1 --fresh' '$STUB_LOG'"
reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "ctl restart en pause anti-boucle : décision humaine, le compteur repart de zéro et lance" bash -c "'$CTL' restart t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; export CLAUDE_RC_NOW=1000; mkdir -p "$CLAUDE_RC_STATE_DIR"; printf '900\n950\n990\n' > "$CLAUDE_RC_STATE_DIR/t1.launches"
check "ctl fresh --yes en pause anti-boucle : lance aussi"       bash -c "'$CTL' fresh t1 --yes >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 1 ]"
reset; alive; export RC_STOP_WAIT=2
check "ctl stop : signale l'échec si le serveur ne disparaît pas" exit_is 1 bash "$CTL" stop t1
reset; alive; export RC_STOP_WAIT=2
check "ctl restart : n'enchaîne PAS un lancement si l'ancien serveur survit" bash -c "! bash '$CTL' restart t1 >/dev/null 2>&1; [ \"\$(grep -c 'new-session' '$STUB_LOG' || true)\" = 0 ]"

echo "== claude-rc-ctl : create / enable / disable / list"
reset; NOM="Nom avec  espaces / é'à"
check "create : écrit la configuration et refuse de démarrer quoi que ce soit" bash -c "'$CTL' create t5 --name \"$NOM\" --dir '$T/w5' >/dev/null 2>&1 && test -f '$CLAUDE_RC_CONFIG_DIR/t5.env' && [ \"\$(grep -c 'new-session\|systemctl' '$STUB_LOG' || true)\" = 0 ]"
check "create : le nom (apostrophe, accents, doubles espaces) est relu à l'identique" bash -c ". '$CLAUDE_RC_CONFIG_DIR/t5.env'; [ \"\$RC_NAME\" = \"$NOM\" ]"
check "create : dossier de travail créé"                          test -d "$T/w5"
check "create : mode acceptEdits et repli never par défaut"       bash -c ". '$CLAUDE_RC_CONFIG_DIR/t5.env'; [ \"\$RC_PERMISSION_MODE\" = acceptEdits ] && [ \"\$RC_FALLBACK\" = never ]"
[ "$LINUX" = 1 ] && check "create : fichier en 600"               test "$(mode_of "$CLAUDE_RC_CONFIG_DIR/t5.env")" = 600
check "create : refuse d'écraser une configuration existante"     bash -c "! '$CTL' create t5 --name X --dir '$T/w6' >/dev/null 2>&1"
check "create : nom déjà pris -> refusé (67) et rien conservé"    bash -c "'$CTL' create t6 --name T1 --dir '$T/w6' >/dev/null 2>&1; [ \$? -eq 67 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create : dossier temporaire refusé (69) et rien conservé"  bash -c "env -u CLAUDE_RC_ALLOW_TMP '$CTL' create t6 --name X6 --dir /tmp/x6 >/dev/null 2>&1; [ \$? -eq 69 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create : mode bypassPermissions refusé (65)"               bash -c "'$CTL' create t6 --name X6 --dir '$T/w6' --mode bypassPermissions >/dev/null 2>&1; [ \$? -eq 65 ] && [ ! -e '$CLAUDE_RC_CONFIG_DIR/t6.env' ]"
check "create : sans --name ou --dir : refusé (64)"               exit_is 64 bash "$CTL" create t6 --name X6
: > "$STUB_LOG"
check "enable avant le premier démarrage : refusé (64), systemctl non appelé" bash -c "'$CTL' enable t5 >/dev/null 2>&1; [ \$? -eq 64 ] && [ \"\$(grep -c systemctl '$STUB_LOG' || true)\" = 0 ]"
mkdir -p "$CLAUDE_RC_STATE_DIR"; date > "$CLAUDE_RC_STATE_DIR/t5.started"
check "enable après un premier démarrage : active le minuteur"    bash -c "'$CTL' enable t5 >/dev/null 2>&1; grep -q 'systemctl --user enable --now claude-rc@t5.timer' '$STUB_LOG'"
check "disable : désactive le minuteur sans tuer la session"      bash -c "'$CTL' disable t5 >/dev/null 2>&1; grep -q 'systemctl --user disable --now claude-rc@t5.timer' '$STUB_LOG' && ! grep -q 'kill' '$STUB_LOG'"
check "list : montre t1 et t5 avec nom et dossier"                bash -c "o=\$('$CTL' list); echo \"\$o\" | grep -q '^t1 ' && echo \"\$o\" | grep -q '^t5 ' && echo \"\$o\" | grep -qF '$T/w5'"
alive
check "list : montre le processus en cours de t1"                 bash -c "'$CTL' list | grep '^t1 ' | grep -q 'pid 4242'"
check "list : affiche la mémoire disponible"                      bash -c "'$CTL' list | grep -q 'mémoire disponible : 5859 Mo'"

echo "== journal : rotation à taille maximale"
reset
check "rotation : le journal devient .log.1 au-delà du plafond"   bash -c ". '$ROOT/lib/common.sh'; RC_ID=t1; RC_LOG_MAX_BYTES=300; for i in \$(seq 1 20); do rc_log INFO \"ligne numero \$i pour remplir le journal\"; done; rc_log INFO fin; test -e '$CLAUDE_RC_STATE_DIR/t1.log.1'"
check "rotation : le journal courant reste petit"                 bash -c "test \"\$(stat -c %s '$CLAUDE_RC_STATE_DIR/t1.log')\" -lt 500"
check "rotation : une seule génération conservée"                 bash -c "! ls '$CLAUDE_RC_STATE_DIR'/t1.log.2 >/dev/null 2>&1"
[ "$LINUX" = 1 ] && check "rotation : les journaux restent en 600" bash -c "[ \"\$(stat -c %a '$CLAUDE_RC_STATE_DIR/t1.log')\" = 600 ] && [ \"\$(stat -c %a '$CLAUDE_RC_STATE_DIR/t1.log.1')\" = 600 ]"
check "plafond par défaut : 1 Mo (1048576)"                       bash -c "grep -q 'RC_LOG_MAX_BYTES:-1048576' '$ROOT/lib/common.sh'"

echo "== permissions (umask 0002, comme sur le VPS)"
if [ "$LINUX" = 1 ]; then
  reset
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "dossier d'état en 700"                                   test "$(mode_of "$CLAUDE_RC_STATE_DIR")" = 700
  check "journal en 600"                                          test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.log")" = 600
  check "fichier d'état (.last) en 600"                           test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.last")" = 600
  check "compteur de lancements en 600"                           test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.launches")" = 600
  check "le dossier de travail garde l'umask normal (775)"        test "$(mode_of "$T/work")" = 775
else skipped "permissions : Linux requis"; fi

echo "== verrou et dossiers d'installation : droits"
if [ "$LINUX" = 1 ] && command -v flock >/dev/null; then
  reset; ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "verrou créé en 600 (umask 0002)"                         test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
  reset; mkdir -p "$CLAUDE_RC_STATE_DIR"; ( umask 0002; : > "$CLAUDE_RC_STATE_DIR/t1.lock" ); chmod 664 "$CLAUDE_RC_STATE_DIR/t1.lock"
  ( umask 0002; bash "$ENSURE" t1 >/dev/null 2>&1 )
  check "verrou existant en 664 : resserré en 600"                test "$(mode_of "$CLAUDE_RC_STATE_DIR/t1.lock")" = 600
else skipped "droits du verrou : Linux + flock requis"; fi
if [ "$LINUX" = 1 ]; then
  H2="$T/home2"; mkdir -p "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.local/bin" "$H2/.config/systemd/user" "$H2/claude-rc/sessions"
  chmod 775 "$H2/.config/claude-rc" "$H2/.local/lib/claude-rc" "$H2/.config/systemd/user" "$H2/claude-rc" "$H2/claude-rc/sessions"; chmod 755 "$H2/.local/bin"
  ( umask 0002; HOME="$H2" XDG_CONFIG_HOME="$H2/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (dossiers existants en 775) : ~/.config/claude-rc resserré en 700"   test "$(mode_of "$H2/.config/claude-rc")" = 700
  check "install (dossiers existants en 775) : ~/.local/lib/claude-rc resserré en 700" test "$(mode_of "$H2/.local/lib/claude-rc")" = 700
  check "install (dossiers existants en 775) : ~/claude-rc/sessions resserré en 700"  test "$(mode_of "$H2/claude-rc/sessions")" = 700
  check "install : ~/.local/bin (dossier partagé) INCHANGÉ (755)"                    test "$(mode_of "$H2/.local/bin")" = 755
  check "install : ~/.config/systemd/user (dossier partagé) INCHANGÉ (775)"          test "$(mode_of "$H2/.config/systemd/user")" = 775
  check "install : exemple de configuration en 600"                                  test "$(mode_of "$H2/.config/claude-rc/session.env.example")" = 600
  check "install : AUCUNE session (aucun fichier .env) n'est créée"                  bash -c "! ls '$H2/.config/claude-rc'/*.env >/dev/null 2>&1"
  check "install : unités en 644 et scripts en 755"                                  bash -c "[ \"\$(stat -c %a '$H2/.config/systemd/user/claude-rc@.timer')\" = 644 ] && [ \"\$(stat -c %a '$H2/.local/lib/claude-rc/claude-rc-run')\" = 755 ]"
  H3="$T/home3"; mkdir -p "$H3"
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "install (HOME neuf, umask 0002) : ~/.config/claude-rc créé en 700"          test "$(mode_of "$H3/.config/claude-rc")" = 700
  check "install (HOME neuf, umask 0002) : ~/.local/lib/claude-rc créé en 700"       test "$(mode_of "$H3/.local/lib/claude-rc")" = 700
  check "install (HOME neuf) : ~/claude-rc et ~/claude-rc/sessions créés en 700"     bash -c "[ \"\$(stat -c %a '$H3/claude-rc')\" = 700 ] && [ \"\$(stat -c %a '$H3/claude-rc/sessions')\" = 700 ]"
  ( umask 0002; HOME="$H3" XDG_CONFIG_HOME="$H3/.config" bash "$ROOT/install.sh" >/dev/null 2>&1 )
  check "réinstallation : les dossiers restent en 700"                               bash -c "[ \"\$(stat -c %a '$H3/.config/claude-rc')\" = 700 ] && [ \"\$(stat -c %a '$H3/.local/lib/claude-rc')\" = 700 ]"
  reset; mkdir -p "$T/cfgex"; cp "$ROOT/conf/session.env.example" "$T/cfgex/exemple.env"
  check "l'exemple de configuration est valide une fois copié (dossier durable simulé)" bash -c "HOME=/home/u CLAUDE_RC_CONFIG_DIR='$T/cfgex' env -u CLAUDE_RC_ALLOW_TMP bash -c '. \"$ROOT/lib/common.sh\"; rc_load_config exemple'"
else skipped "droits des dossiers d'installation : Linux requis"; fi

echo "== détection du processus : motif de pgrep -f (testé sur de vraies lignes de commande)"
# shellcheck disable=SC1091
. "$ROOT/lib/common.sh"
matches() { printf '%s\n' "$1" | grep -Eq -- "$RC_SERVER_PATTERN"; }
check "reconnaît « claude remote-control … »"                     matches "claude remote-control --name X --permission-mode acceptEdits"
check "reconnaît le chemin absolu de claude"                      matches "/home/u/.local/bin/claude remote-control --name X --continue"
check "reconnaît « claude remote-control » sans option"           matches "claude remote-control"
check "reconnaît un nom avec espaces et accents"                  matches "claude remote-control --name Projet.ai/Démo  éà --permission-mode acceptEdits"
check "ne confond pas avec le processus tmux qui le contient"     bash -c "! printf '%s\n' 'tmux new-session -d -s rc claude remote-control --name X' | grep -Eq -- '$RC_SERVER_PATTERN'"
check "ne confond pas avec un autre sous-commande de claude"      bash -c "! printf '%s\n' 'claude auth status' | grep -Eq -- '$RC_SERVER_PATTERN'"
check "ne confond pas avec « claude remote-controller »"          bash -c "! printf '%s\n' 'claude remote-controller' | grep -Eq -- '$RC_SERVER_PATTERN'"

echo "== installation"
check "install.sh --dry-run : code 0"                             exit_is 0 bash "$ROOT/install.sh" --dry-run
check "install.sh --dry-run : n'écrit RIEN"                       test ! -e "$T/home/.local" -a ! -e "$T/home/.config" -a ! -e "$T/home/claude-rc"
check "install.sh --dry-run : annonce les unités et les sessions" bash -c "'$ROOT/install.sh' --dry-run | grep -q 'claude-rc@.timer' && '$ROOT/install.sh' --dry-run | grep -q 'claude-rc/sessions'"
check "uninstall.sh --dry-run : code 0 et n'écrit rien"           bash -c "'$ROOT/uninstall.sh' --dry-run >/dev/null && test ! -e '$T/home/.local'"
check "install.sh / uninstall.sh : ni kill, ni tmux, ni stop"     bash -c "! grep -nE '\\b(kill|pkill|tmux|restart)\\b|systemctl.* stop' '$ROOT/install.sh' '$ROOT/uninstall.sh'"
check "install.sh ne démarre ni n'active rien (pas d'enable/start)" bash -c "! grep -nE 'systemctl.*(enable|start)' '$ROOT/install.sh'"

echo "== unités systemd et hygiène"
S="$ROOT/systemd/user/claude-rc@.service"; M="$ROOT/systemd/user/claude-rc@.timer"
check "service : Type=oneshot"                                    grep -q '^Type=oneshot' "$S"
check "service : KillMode=process (tmux survit)"                  grep -q '^KillMode=process' "$S"
check "service : ExecStart vers claude-rc-ensure %i"              grep -q '^ExecStart=%h/.local/lib/claude-rc/claude-rc-ensure %i' "$S"
check "service : PATH explicite avec ~/.local/bin"                grep -q '^Environment=PATH=%h/.local/bin' "$S"
check "service : ne démarre pas sans fichier de configuration"    grep -q '^ConditionPathExists=%E/claude-rc/%i.env' "$S"
check "service : pas de UMask forcé (tmux et claude héritent de l'umask normal)" bash -c "! grep -q '^UMask=' '$S'"
check "minuteur : OnBootSec=60s"                                  grep -q '^OnBootSec=60s' "$M"
check "minuteur : OnUnitInactiveSec=60s"                          grep -q '^OnUnitInactiveSec=60s' "$M"
check "minuteur : AccuracySec=1s"                                 grep -q '^AccuracySec=1s' "$M"
check "minuteur : RandomizedDelaySec=30s (plusieurs sessions étalées)" grep -q '^RandomizedDelaySec=30s' "$M"
check "minuteur : WantedBy=timers.target"                         grep -q '^WantedBy=timers.target' "$M"
echo "== cache de la v�rification de connexion"
export CLAUDE_BIN="$STUBS/claude"
authcalls() { grep -c 'claude auth status' "$STUB_LOG" || true; }
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=1000
check "cache : 1er appel, connexion OK"                           exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache : 1er appel = 1 vraie v�rification"                  test "$(authcalls)" = 1
export CLAUDE_RC_NOW=1100
check "cache : 2e appel (100 s) encore OK"                        exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache : 2e appel sans nouvelle v�rification"               test "$(authcalls)" = 1
export CLAUDE_RC_NOW=1400 STUB_AUTH=ko
check "cache : expir� (400 s) + connexion perdue = invalide"      exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache : expir� = nouvelle v�rification"                    test "$(authcalls)" = 2
check "cache : un �chec efface le cache"                          test ! -e "$CLAUDE_RC_STATE_DIR/auth-ok"
export CLAUDE_RC_NOW=1401
check "cache : un �chec n'est jamais retenu"                      exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache : donc rev�rifi� � chaque fois"                      test "$(authcalls)" = 3
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=2000
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"; export STUB_AUTH=ko CLAUDE_RC_NOW=2010
check "cache : RC_AUTH_FRESH=1 ignore le cache"                   exit_is 1 env RC_AUTH_FRESH=1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; export RC_AUTH_CACHE_SECONDS=0 CLAUDE_RC_NOW=3000
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok; rc_auth_ok"
check "cache : 0 = d�sactiv� (2 v�rifications)"                   test "$(authcalls)" = 2
check "cache : 0 = aucun fichier �crit"                           test ! -e "$CLAUDE_RC_STATE_DIR/auth-ok"
reset; export RC_AUTH_CACHE_SECONDS=300 CLAUDE_RC_NOW=100
mkdir -p "$CLAUDE_RC_STATE_DIR"; echo 5000 > "$CLAUDE_RC_STATE_DIR/auth-ok"
bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "cache : horodatage dans le futur ignor�"                   test "$(authcalls)" = 1
export RC_AUTH_CACHE_SECONDS=0; unset CLAUDE_RC_NOW STUB_AUTH
reset

echo "== contr�le de connexion : lecture du fichier, sans lancer claude"
setcred() { mkdir -p "$T/cc"; printf '%s
' "$1" > "$T/cc/.credentials.json"; }
reset; setcred '{"claudeAiOauth":{"accessToken":"x","refreshToken":"y","expiresAt":1}}'
check "fichier avec jeton de renouvellement : OK"                 exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "fichier avec jeton : claude n'est PAS lanc�"               test "$(authcalls)" = 0
export STUB_AUTH=ko
check "fichier avec jeton : OK m�me si le CLI dirait non"         exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "RC_AUTH_FRESH=1 interroge le CLI"                          exit_is 1 env RC_AUTH_FRESH=1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "RC_AUTH_MODE=cli interroge le CLI"                         exit_is 1 env RC_AUTH_MODE=cli bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; setcred '{"claudeAiOauth":{"accessToken":"x"}}'
check "fichier sans jeton de renouvellement : le CLI d�cide"      exit_is 0 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
check "fichier sans jeton : claude a bien �t� interrog�"          test "$(authcalls)" = 1
reset; setcred '{"claudeAiOauth":{"refreshToken":""}}'; export STUB_AUTH=ko
check "jeton vide : connexion invalide"                           exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset; export STUB_AUTH=ko
check "fichier absent : le CLI d�cide (invalide)"                 exit_is 1 bash -c ". '$ROOT/lib/common.sh'; rc_auth_ok"
reset

for f in bin/claude-rc-ensure bin/claude-rc-run bin/claude-rc-ctl lib/common.sh install.sh uninstall.sh tests/run-tests.sh tests/hygiene.sh; do
  check "syntaxe bash : $f"                                       bash -n "$ROOT/$f"
done
echo "== hygiène du dépôt avant publication (détail : tests/hygiene.sh)"
check "hygiène : aucune clé, IPv4, e-mail ni longue chaîne aléatoire, ni terme de la liste personnelle" bash "$ROOT/tests/hygiene.sh"
[ -f "$ROOT/tests/private-patterns.local" ] || skipped "liste personnelle absente (tests/private-patterns.local) : À CRÉER avant de publier"

echo
echo "Résultat : $pass réussi(s), $fail échec(s), $skip ignoré(s)"
[ "$fail" -eq 0 ]

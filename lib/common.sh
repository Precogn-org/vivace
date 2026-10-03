#!/usr/bin/env bash
# claude-rc-keepalive : fonctions communes. À « sourcer », pas à exécuter.
# Licence : MIT (voir LICENSE)
#
# Variables d'environnement reconnues (surtout pour les tests) :
#   CLAUDE_RC_CONFIG_DIR    dossier des fichiers <id>.env   (défaut : ~/.config/claude-rc)
#   CLAUDE_RC_STATE_DIR     journaux, verrous, drapeaux     (défaut : ~/.local/state/claude-rc)
#   CLAUDE_RC_NOW           heure forcée en secondes
#   CLAUDE_RC_SCREEN_FILE   texte d'écran forcé (remplace `tmux capture-pane`)
#   CLAUDE_RC_PROC_ROOT     racine « /proc » (tests)
#   CLAUDE_RC_MEMINFO       fichier « meminfo » (tests)
#   CLAUDE_RC_ALLOW_TMP=1   autorise un dossier de travail temporaire (tests uniquement)

: "${CLAUDE_RC_CONFIG_DIR:=${XDG_CONFIG_HOME:-$HOME/.config}/claude-rc}"
: "${CLAUDE_RC_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/claude-rc}"

# Motif (pour pgrep -f / grep -E) d'un serveur `claude remote-control` : « claude » (éventuellement avec son chemin)
# en premier mot, puis « remote-control ». Ne reconnaît PAS le processus tmux ou bash qui le contient.
RC_SERVER_PATTERN='^([^ ]*/)?claude remote-control( |$)'

rc_now() { if [ -n "${CLAUDE_RC_NOW:-}" ]; then echo "$CLAUDE_RC_NOW"; else date +%s; fi; }

# Horloge MONOTONE (secondes) pour mesurer des durées : insensible aux corrections de l'heure système
# (fréquentes juste après un démarrage, quand l'heure est recalée). rc_now reste l'heure réelle (fenêtre anti-boucle).
rc_mono() { local up; if [ -r /proc/uptime ]; then read -r up _ < /proc/uptime; echo "${up%.*}"; else date +%s; fi; }

# Tout ce que ces scripts ÉCRIVENT dans le dossier d'état est en 600/700, quel que soit l'umask de l'utilisateur.
# (Le umask n'est PAS changé pour le reste du script : tmux et claude héritent de l'umask normal.)
rc_mkstate() { ( umask 077; mkdir -p "$CLAUDE_RC_STATE_DIR" ) && chmod 700 "$CLAUDE_RC_STATE_DIR" 2>/dev/null || true; }
rc_append()  { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s\n' "$*" >> "$f" ); }
rc_write()   { local f=$1; shift; rc_mkstate; ( umask 077; printf '%s' "$*" > "$f" ); }

# rc_log NIVEAU message...   -> une ligne horodatée (UTC) dans <état>/<id>.log
# Rotation : au-delà de RC_LOG_MAX_BYTES (1 Mo par défaut) le journal devient <id>.log.1 (une seule génération conservée).
rc_log() {
  local level=$1; shift
  local f="$CLAUDE_RC_STATE_DIR/${RC_ID:-claude-rc}.log" max=${RC_LOG_MAX_BYTES:-1048576} size
  rc_append "$f" "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$level] $*"
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [[ $size =~ ^[0-9]+$ ]] && [[ $max =~ ^[0-9]+$ ]] && [ "$size" -gt "$max" ]; then
    mv -f "$f" "$f.1" 2>/dev/null || true
  fi
}

# rc_note NIVEAU ETAT message...   -> journalise seulement quand l'ETAT change (évite 1 ligne par minute)
rc_note() {
  local level=$1 state=$2; shift 2
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.last"
  if [ "$(cat "$f" 2>/dev/null || true)" != "$state" ]; then
    rc_log "$level" "$*"
    rc_write "$f" "$state"
  fi
}

# Chemin canonique (liens symboliques résolus) ; si impossible, le chemin tel quel.
rc_realdir() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }

# Chaîne entre apostrophes, sûre à écrire dans un fichier shell (même avec espaces, accents, apostrophes).
rc_squote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# Un nom de session est libre (espaces, accents, « / », doubles espaces…) mais : non vide, sans caractère de
# contrôle, sans « - » initial (il serait pris pour une option), 120 caractères au plus.
rc_valid_name() {
  local n=$1
  [ -n "$n" ] || return 1
  [ "${#n}" -le 120 ] || return 1
  case "$n" in -*) return 1 ;; esac
  [[ $n =~ [[:cntrl:]] ]] && return 1
  return 0
}

# Un dossier de travail doit être absolu et durable : jamais /tmp, /var/tmp, /dev/shm, /run (vidés au démarrage).
rc_valid_dir() {
  local d=$1
  case "$d" in /*) ;; *) return 1 ;; esac
  [ "${CLAUDE_RC_ALLOW_TMP:-0}" = 1 ] && return 0
  case "$(rc_realdir "$d")" in
    /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run|/run/*|/var/run|/var/run/*) return 1 ;;
  esac
  return 0
}

# rc_load_config ID -> charge <config>/<ID>.env et pose les variables RC_*.
# Codes : 64 identifiant invalide, 65 mode de permission refusé, 66 configuration absente,
#         67 nom ou dossier déjà utilisé par une autre instance, 68 nom de session invalide,
#         69 dossier de travail refusé (relatif ou temporaire), 70 RC_FALLBACK invalide,
#         71 réglage numérique invalide.
rc_load_config() {
  RC_ID=${1:-}
  case "$RC_ID" in
    ''|*[!a-z0-9._-]*) echo "identifiant invalide : '$RC_ID' (minuscules, chiffres, . _ - seulement)" >&2; return 64 ;;
  esac
  local f="$CLAUDE_RC_CONFIG_DIR/$RC_ID.env"
  [ -r "$f" ] || { echo "configuration introuvable : $f" >&2; return 66; }
  # Le fichier est du shell : il appartient à l'utilisateur et n'est jamais modifié par ces scripts.
  # shellcheck disable=SC1090
  . "$f"
  : "${RC_NAME:?RC_NAME manquant dans $f}"
  : "${RC_DIR:?RC_DIR manquant dans $f}"
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
  rc_valid_name "$RC_NAME" || { echo "RC_NAME invalide : '$RC_NAME' (1 à 120 caractères, sans caractère de contrôle, ne commence pas par « - »)" >&2; return 68; }
  rc_valid_dir "$RC_DIR" || { echo "RC_DIR refusé : '$RC_DIR' (chemin absolu et durable requis ; jamais /tmp, /var/tmp, /dev/shm, /run)" >&2; return 69; }
  # Liste blanche volontairement courte : jamais de bypassPermissions, ni de dontAsk, ni d'auto.
  case "$RC_PERMISSION_MODE" in
    default|acceptEdits|plan) ;;
    *) echo "mode de permission refusé : '$RC_PERMISSION_MODE' (autorisés : default, acceptEdits, plan)" >&2; return 65 ;;
  esac
  case "$RC_FALLBACK" in
    never|norecord) ;;
    *) echo "RC_FALLBACK invalide : '$RC_FALLBACK' (never ou norecord)" >&2; return 70 ;;
  esac
  local v
  for v in "$RC_CONTINUE_FAIL_SECONDS" "$RC_MAX_LAUNCHES" "$RC_LAUNCH_WINDOW" "$RC_STOP_WAIT" "$RC_MIN_AVAILABLE_MB" "$RC_LOG_MAX_BYTES"; do
    [[ $v =~ ^[0-9]+$ ]] || { echo "réglage numérique invalide : '$v'" >&2; return 71; }
  done
  RC_STOP_FLAG="$CLAUDE_RC_STATE_DIR/$RC_ID.stop"
  RC_LAUNCHES="$CLAUDE_RC_STATE_DIR/$RC_ID.launches"
  RC_STARTED="$CLAUDE_RC_STATE_DIR/$RC_ID.started"
  rc_check_unique "$f" || return 67
  return 0
}

# Deux instances ne doivent partager NI le nom NI le dossier : --continue est lié au dossier, et un serveur
# refuse de démarrer là où un autre tourne ; un partage ferait reprendre ou doubler la mauvaise session.
rc_check_unique() {
  local self=$1 other o_name o_dir mydir
  mydir=$(rc_realdir "$RC_DIR")
  for other in "$CLAUDE_RC_CONFIG_DIR"/*.env; do
    [ -e "$other" ] && [ "$other" != "$self" ] || continue
    o_name=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_NAME:-}" )
    o_dir=$( . "$other" >/dev/null 2>&1; printf '%s' "${RC_DIR:-}" )
    o_dir=$(rc_realdir "${o_dir%/}")
    if [ "$o_name" = "$RC_NAME" ]; then echo "RC_NAME '$RC_NAME' déjà utilisé par $(basename "$other")" >&2; return 1; fi
    if [ "$o_dir" = "$mydir" ]; then echo "RC_DIR '$RC_DIR' déjà utilisé par $(basename "$other")" >&2; return 1; fi
  done
  return 0
}

rc_escape_ere() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# PID(s) du serveur `claude remote-control` de l'utilisateur courant QUI TRAVAILLE DANS RC_DIR.
# Détection par le DOSSIER DE TRAVAIL du processus (/proc/<pid>/cwd), pas par son nom : le nom peut contenir
# n'importe quoi (espaces, accents…) et deux sessions ne partagent jamais un dossier. Une session lancée à la main
# dans le même dossier est ainsi « adoptée » au lieu d'être doublée.
rc_server_pids() {
  local proc=${CLAUDE_RC_PROC_ROOT:-/proc} want pid cwd
  want=$(rc_realdir "$RC_DIR")
  for pid in $(pgrep -u "$(id -u)" -f "$RC_SERVER_PATTERN" 2>/dev/null); do
    cwd=$(readlink -f -- "$proc/$pid/cwd" 2>/dev/null) || continue
    [ "$cwd" = "$want" ] && echo "$pid"
  done
  return 0
}

# Sessions Remote Control de l'utilisateur, QUELLE QUE SOIT leur méthode de lancement (lecture de /proc) :
#   serveur      claude remote-control --name <NOM> ...   (celles de claude-rc-keepalive, ou lancées à la main)
#   interactive  claude --remote-control <NOM> ...        (par exemple dans une fenêtre tmux, hors claude-rc-keepalive)
# Une ligne par processus : « pid<TAB>forme<TAB>dossier<TAB>nom ». Les arguments sont lus séparés par NUL : un nom
# avec espaces ou accents est donc lu correctement. Un `claude --name ...` ordinaire (hors Remote Control) n'est pas compté.
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
          --name)   form=serveur; name=${args[i+1]-}; break ;;
          --name=*) form=serveur; name=${args[i]#--name=}; break ;;
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

# Noms portés par PLUSIEURS processus : « nom<TAB>pid<TAB>forme<TAB>dossier », regroupés par nom.
rc_duplicate_names() {
  rc_named_sessions | awk -F'\t' '
    { n[$4]++; row[NR] = $4 "\t" $1 "\t" $2 "\t" $3; nm[NR] = $4 }
    END { for (i = 1; i <= NR; i++) if (n[nm[i]] > 1) print row[i] }' | sort -t$'\t' -k1,1 -k2,2n
}

# Processus qui portent le nom de CETTE instance (RC_NAME) sans être l'un de ses propres serveurs (ceux du dossier
# RC_DIR) : « pid<TAB>forme<TAB>dossier ». Lancer un serveur de plus créerait un doublon.
rc_name_conflicts() {
  local own pid form cwd name
  own=" $(rc_server_pids | tr '\n' ' ') "
  while IFS=$'\t' read -r pid form cwd name; do
    [ "$name" = "$RC_NAME" ] || continue
    case "$own" in *" $pid "*) continue ;; esac
    printf '%s\t%s\t%s\n' "$pid" "$form" "$cwd"
  done < <(rc_named_sessions)
}

# Mémoire réellement disponible (Mo), depuis /proc/meminfo ; vide si illisible.
rc_mem_available_mb() {
  local f=${CLAUDE_RC_MEMINFO:-/proc/meminfo} kb
  kb=$(awk '/^MemAvailable:/ {print $2; exit}' "$f" 2>/dev/null)
  [[ $kb =~ ^[0-9]+$ ]] && echo $((kb / 1024))
  return 0
}

# Mémoire résidente (Ko) d'un processus et de tous ses descendants.
rc_tree_rss_kb() {
  ps -eo pid=,ppid=,rss= 2>/dev/null | awk -v root="$1" '
    { p[$1] = $2; r[$1] = $3 }
    END { tot = 0
          for (i in p) { x = i; n = 0
            while (x != "" && x != 0 && n++ < 64) { if (x == root) { tot += r[i]; break }; x = p[x] } }
          print tot }'
}

# API Anthropic joignable ? (toute réponse HTTP suffit ; seule une panne réseau/DNS/TLS échoue)
rc_network_ok() { curl -sS -o /dev/null -m 8 --connect-timeout 5 https://api.anthropic.com/ >/dev/null 2>&1; }

# Connexion Claude valide ? (claude auth status affiche du JSON avec "loggedIn": true)
# Un r�sultat POSITIF est retenu RC_AUTH_CACHE_SECONDS (d�faut 300 ; 0 = pas de cache) dans un fichier commun � toutes les
# instances : N instances ne font plus N appels par minute. Un r�sultat n�gatif n'est jamais retenu (et efface le cache).
# RC_AUTH_FRESH=1 force une vraie v�rification (utilis� par � claude-rc-ctl status �).
rc_auth_ok() {
  local f="$CLAUDE_RC_STATE_DIR/auth-ok" ttl=${RC_AUTH_CACHE_SECONDS:-300} now ts=""
  case "$ttl" in ''|*[!0-9]*) ttl=300 ;; esac
  now=$(rc_now)
  # Mode � file � (d�faut) : on LIT le fichier d'identifiants sans lancer claude. Lancer � claude auth status � peut
  # d�clencher un renouvellement du jeton, en concurrence avec celui des sessions : c'est ce qui a fait perdre la connexion.
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

# Verrou non bloquant par instance : empêche deux exécutions simultanées (minuteur + commande manuelle)
# de lancer chacune une session. Sans `flock` (util-linux), pas de verrou.
# Le descripteur 9 ne doit PAS être hérité par tmux : le lancement se fait avec « 9>&- ».
rc_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  rc_mkstate
  local f="$CLAUDE_RC_STATE_DIR/$RC_ID.lock"
  ( umask 077; : >> "$f" ) 2>/dev/null   # créé en 600 s'il n'existe pas...
  chmod 600 "$f" 2>/dev/null || true      # ...et resserré s'il existait déjà plus large
  exec 9>>"$f" || return 0
  flock -n 9
}

# Texte de l'écran du panneau tmux courant (les messages d'erreur de claude y sont affichés).
rc_screen() {
  if [ -n "${CLAUDE_RC_SCREEN_FILE:-}" ]; then cat "$CLAUDE_RC_SCREEN_FILE" 2>/dev/null; return 0; fi
  [ -n "${TMUX_PANE:-}" ] && tmux capture-pane -p -J -S -200 -t "$TMUX_PANE" 2>/dev/null
  return 0
}

# Garde-fou anti-boucle : au plus RC_MAX_LAUNCHES lancements par fenêtre glissante de RC_LAUNCH_WINDOW secondes.
# Au-delà, une pause (code 4) ; elle se lève d'elle-même quand les lancements les plus anciens sortent de la fenêtre.
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

# Marque « cette instance a déjà démarré au moins une fois » : `claude-rc-ctl enable` l'exige (sinon la première
# session doit d'abord être créée explicitement par `claude-rc-ctl fresh <id> --yes`).
rc_mark_started() { rc_write "$RC_STARTED" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; }

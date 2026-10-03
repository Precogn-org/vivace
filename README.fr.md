# claude-rc-keepalive

> **Nom du produit : Vivace.** Ce dépôt (`claude-rc-keepalive`) est le moteur de **Vivace** — il garde les agents Claude Code allumés et pilotables « en remote live ».

🇬🇧 [English](README.md) · 🇫🇷 Français

Maintient en vie des **sessions Claude Code Remote Control** sur une machine Linux toujours allumée (VPS, mini-PC) :
chacune est relancée après un arrêt ou un redémarrage et, autant que possible, **reprend la même session claude.ai**, pour
continuer à la piloter depuis un téléphone, une tablette ou claude.ai/code. Une instance = une session = un dossier de travail.

> **Statut : v2.2, testée avec une vraie session** (Claude Code 2.1.282, Ubuntu 24.04) : vrai arrêt brutal, reprise par le
> minuteur, redémarrage, pause anti-boucle puis reprise automatique ; la reprise après redémarrage de la machine a été
> vérifiée sur la version précédente (v2.1). Plusieurs points restent non vérifiés (fenêtre de reprise d'environ 4 h,
> réseau tardif au démarrage…) : voir [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md). Sans lien avec Anthropic, non approuvé par elle.
> Note : les messages de journal et les commentaires du code sont pour l'instant en français ; la documentation est bilingue.
> Changements : [CHANGELOG.md](CHANGELOG.md).

## Pourquoi

`claude remote-control` est un processus **local** : s'il s'arrête (redémarrage, longue coupure réseau, plantage), la
session passe « hors ligne » et rien ne la relance. La documentation officielle recommande `tmux` ou `screen` sur une
machine distante mais ne décrit ni démarrage automatique ni supervision. Ce dépôt en propose une réponse minimale :
quelques scripts shell et deux unités systemd **utilisateur** (aucun droit administrateur).

## Fonctionnement

```
   démarrage machine ─(60 s)─┐            chaque minute ─┐
                              ▼                          ▼
                 claude-rc@<id>.timer ───────► claude-rc@<id>.service (oneshot, ~1 s)
                                                          │  claude-rc-ensure <id>
                                                          ▼
        une autre vérification en cours ? ─oui─► la laisser finir      (verrou flock)
        arrêt volontaire demandé ?         ─oui─► ne rien faire        (drapeau <id>.stop)
        serveur déjà dans ce dossier ?     ─oui─► vérifier la connexion Claude (une session lancée à la main est ADOPTÉE)
        API Anthropic joignable ?          ─non─► attendre             (jamais de nouvelle session « par erreur » à cause du réseau)
        connexion Claude valide ?          ─non─► le journaliser, code 3
        trop de lancements récents ?       ─oui─► pause, code 4        (reprend seule)
        assez de mémoire disponible ?      ─non─► le journaliser, code 8 (rien n'est lancé)
                 │
                 ▼
        tmux new-session ─► claude-rc-run <id>
                                 └─ claude remote-control --name … --continue                (même session claude.ai)
                                         │ en cas d'échec le MESSAGE décide (le code de sortie est toujours 1)
                                         ├─ « No recent session found » ─► RC_FALLBACK=never (défaut) : rien, code 7
                                         │                                  RC_FALLBACK=norecord : NOUVELLE session (seul cas)
                                         ├─ « already being served / already running » ─► rien (doublon évité)
                                         └─ tout autre message                         ─► rien (décision humaine)
```

Pourquoi lire le message : `--continue` sort avec le code 1 aussi bien quand il n'y a **rien à reprendre** que quand **la
session est déjà servie** par un autre processus. Traiter tout échec comme « créer une nouvelle session » créerait des
doublons. **Une nouvelle session n'est jamais créée en silence** : seuls `claude-rc-ctl fresh <id> --yes` (explicite) ou
`RC_FALLBACK=norecord` (activé volontairement, et seulement pour le message « No recent session found ») le font. Tous les
messages connus sont listés dans [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md).

**La détection du serveur se fait par le dossier de travail, pas par le nom** : une instance possède un dossier, et un
processus `claude remote-control` dont le répertoire courant (`/proc/<pid>/cwd`) est ce dossier est « son » serveur. Les noms
de session sont donc libres (espaces, accents, `/`, doubles espaces…).

## Prérequis

- Linux avec **systemd** (gestionnaire utilisateur), `tmux`, `curl`, `bash`, `pgrep`, `flock` (util-linux ; sans lui, pas de verrou).
- [Claude Code](https://code.claude.com/docs/fr/quickstart) installé et **connecté** (`claude auth login`, compte claude.ai :
  Pro, Max, Team ou Enterprise ; les clés d'API ne fonctionnent pas avec Remote Control).
- `loginctl enable-linger <utilisateur>` (vérifier avec `loginctl show-user $USER -p Linger` → `Linger=yes`), sinon le
  minuteur ne démarre qu'à la première connexion.
- Chaque dossier de travail déjà **approuvé** par Claude Code (dialogue « trust » : lancer `claude` une fois dedans).

## Contenu

Dans le dépôt :

```
bin/claude-rc-ensure      vérifie / relance (appelé par le minuteur)
bin/claude-rc-run         s'exécute dans tmux : --continue, puis, selon le message et RC_FALLBACK, une nouvelle session
bin/claude-rc-ctl         list | create | enable | disable | status | start | stop | restart | fresh | logs | screen
lib/common.sh             fonctions communes
systemd/user/claude-rc@.service   unité modèle (oneshot, KillMode=process)
systemd/user/claude-rc@.timer     minuteur modèle (60 s après le démarrage, puis chaque minute, étalé sur 30 s)
conf/session.env.example          exemple de configuration d'une session
install.sh / uninstall.sh         (--dry-run disponible)
tests/run-tests.sh                essais automatiques avec faux claude/tmux/curl/pgrep/systemctl et faux /proc
tests/hygiene.sh                  balayage avant publication (clés, IPv4, e-mails, termes personnels)
docs/VERIFIED.fr.md               vérifié / non vérifié, messages de Claude Code
```

Créé par `install.sh` (uniquement dans le dossier personnel de l'utilisateur) :

| Chemin | Droits | Rôle |
|---|---|---|
| `~/.local/lib/claude-rc/` (4 fichiers) | dossier **700**, scripts 755, `common.sh` 644 | scripts |
| `~/.local/bin/claude-rc-ctl` | lien symbolique | commande |
| `~/.config/systemd/user/claude-rc@.service`, `claude-rc@.timer` | 644 | unités |
| `~/.config/claude-rc/` et `session.env.example` | dossier **700**, fichier **600** (jamais écrasé) | configuration (un `<id>.env` par session) |
| `~/claude-rc/sessions/` | dossier **700** | dossiers de travail durables pour les sessions sans dossier de projet |

Créé à l'exécution, **tout en 600 dans un dossier 700** : `~/.local/state/claude-rc/<id>.{log,log.1,last,launches,started,stop,lock}`.
Les dossiers partagés (`~/.local/bin`, `~/.config/systemd/user`) ne sont jamais modifiés. **`install.sh` ne crée aucune
session et ne démarre rien.**

## Installation

```bash
./install.sh --dry-run          # affiche tout ce qu'il ferait, n'écrit rien
./install.sh                    # copie les fichiers ; ne crée aucune session, ne démarre RIEN
```

## Créer une session

```bash
claude-rc-ctl create mon-projet --name "Mon projet / v2" --dir ~/projects/mon-projet
claude-rc-ctl fresh  mon-projet --yes    # première session, demandée explicitement
claude-rc-ctl enable mon-projet          # démarrage automatique (reprise par --continue) à partir de maintenant
claude-rc-ctl list
```

- `create` valide puis écrit `~/.config/claude-rc/mon-projet.env` (droits 600) ; il ne démarre rien.
- `fresh --yes` crée la session claude.ai. Il passe `--spawn same-dir` car une **nouvelle** session pose sinon une question
  interactive (« Spawn mode ? [1/2] ») la première fois dans un dossier, ce qui bloquerait un démarrage sans humain.
- `enable` refuse tant que l'instance n'a jamais démarré (sinon le premier lancement trouverait « rien à reprendre »).
- Une session **déjà lancée à la main** dans le même dossier est **adoptée** : le minuteur la voit vivante et n'y touche pas ;
  il ne prend le relais qu'au prochain arrêt.
- Les dossiers de travail doivent être **absolus et durables** : `/tmp`, `/var/tmp`, `/dev/shm` et `/run` sont refusés
  (vidés au démarrage). Deux instances ne peuvent partager ni le nom ni le dossier.

## Désinstallation

```bash
./uninstall.sh --dry-run
./uninstall.sh                  # supprime unités et scripts ; les sessions en cours ne sont PAS arrêtées
./uninstall.sh --purge          # supprime aussi configurations et journaux
```

## Usage courant

```bash
claude-rc-ctl list                       # toutes les sessions : nom, dossier, minuteur, processus, mémoire
claude-rc-ctl status  <id>               # état, mémoire, connexion Claude, dernières lignes du journal
claude-rc-ctl stop    <id>               # arrêt VOLONTAIRE : le minuteur ne la relancera pas avant « start »
claude-rc-ctl start   <id>               # retire l'arrêt volontaire et lance (reprise par --continue)
claude-rc-ctl restart <id>               # arrête le processus (et attend sa disparition), relance avec --continue
claude-rc-ctl fresh   <id> --yes         # NOUVELLE session (l'ancienne restera hors ligne dans claude.ai : à archiver)
claude-rc-ctl disable <id>               # coupe le minuteur ; la session en cours n'est PAS arrêtée
claude-rc-ctl logs    <id> 100           # journal
claude-rc-ctl screen  <id>               # écran actuel de la session (lecture seule)
tmux attach -t rc-<id>                   # regarder/piloter la session dans un terminal (Ctrl-b d pour quitter)
```

`start`, `restart` et `fresh` sont des décisions humaines : elles remettent aussi le compteur anti-boucle à zéro.

## Faire parler les sessions entre elles

Chaque instance maintenue est un processus `claude remote-control` indépendant : rien ici ne les rend conscientes
les unes des autres. Si une session essaie de joindre une autre avec **`mcp__ccd_session_mgmt__send_message`** —
l'outil utilisé par les sessions que l'app Claude Code Desktop lance ou suit elle-même — elle échoue généralement à
atteindre une instance `claude remote-control` autonome, car ce registre ne connaît que les sessions gérées par
l'app.

Il existe une **paire `SendMessage` / `ListAgents` native, distincte**, indépendante de l'app Desktop, qui atteint
bien ces instances (testé et confirmé sur 2.1.283, dans les deux sens, vérifié directement dans la transcription du
destinataire — pas seulement une réponse `success: true`). Si une session doit contacter une autre instance
maintenue, dis-lui d'utiliser l'outil `SendMessage` natif, pas `ccd_session_mgmt`. Voir
[anthropics/claude-code#89938](https://github.com/anthropics/claude-code/issues/89938) pour le contexte : la
messagerie inter-sessions par le chemin suivi par l'app a un bug de livraison connu, encore ouvert, sur exactement
cette configuration (sessions `claude remote-control --spawn=same-dir` longue durée dans tmux) ; le chemin natif
n'était pas affecté dans nos tests.

## Configuration (`~/.config/claude-rc/<id>.env`)

Syntaxe shell, **aucun secret**. Voir [conf/session.env.example](conf/session.env.example).

| Variable | Défaut | Rôle |
|---|---|---|
| `RC_NAME` | (obligatoire) | nom affiché dans claude.ai/code et l'appli mobile ; texte libre (1 à 120 caractères, sans caractère de contrôle, ne commence pas par `-`) |
| `RC_DIR` | (obligatoire) | dossier de travail absolu et durable, unique par instance |
| `RC_PERMISSION_MODE` | `acceptEdits` | `default`, `acceptEdits` ou `plan` (**`bypassPermissions`, `auto`, `dontAsk` sont refusés**) |
| `RC_FALLBACK` | `never` | `never` : jamais de nouvelle session sans demande ; `norecord` : nouvelle session seulement sur « No recent session found » |
| `RC_MIN_AVAILABLE_MB` | `1024` | ne rien lancer si `MemAvailable` est inférieure (code 8) |
| `RC_ALLOW_SAME_NAME` | `0` | `1` lève le garde-fou des noms en double (code 9) : seulement si deux processus de même nom sont vraiment voulus |
| `RC_MAX_LAUNCHES` / `RC_LAUNCH_WINDOW` | `3` / `600` | anti-boucle : au plus N lancements par fenêtre de M secondes, puis pause automatique |
| `RC_LOG_MAX_BYTES` | `1048576` | rotation du journal : `<id>.log` devient `<id>.log.1` (une génération conservée) |
| `RC_CONTINUE_FAIL_SECONDS` | `45` | un échec de `--continue` avant ce délai est analysé (message lu à l'écran) |

## Codes de sortie

`claude-rc-ensure` :

| Code | Signification |
|---|---|
| 0 | tout va bien (en cours, lancé, arrêt volontaire, réseau absent, ou une vérification est déjà en cours) |
| 1 | tmux n'a pas pu démarrer / dossier de travail impossible à créer |
| 3 | connexion Claude invalide : rien n'est lancé (le service apparaît « failed ») |
| 4 | pause anti-boucle (3 lancements en 10 minutes) ; **reprend seule** quand la fenêtre est écoulée |
| 8 | mémoire disponible insuffisante (`RC_MIN_AVAILABLE_MB`) : rien n'est lancé |
| 9 | un autre processus porte déjà le même nom de session (un jumeau, lancé autrement, par exemple `claude --remote-control <nom>` dans une fenêtre tmux) : rien n'est lancé |
| 64-71 | configuration invalide : 64 identifiant, 65 mode de permission, 66 absente, 67 nom/dossier déjà pris, 68 nom invalide, 69 dossier relatif ou temporaire, 70 `RC_FALLBACK` invalide, 71 nombre invalide |

`claude-rc-run` : le code de claude lui-même, ou **5** (session déjà servie par une autre instance), **6** (échec inconnu de
`--continue`, ou session jamais rattachée), **7** (rien à reprendre et `RC_FALLBACK=never`).

## Que se passe-t-il quand…

- **la machine redémarre** : le gestionnaire utilisateur démarre (grâce à linger) et chaque minuteur se déclenche environ
  60 s après le démarrage (plus jusqu'à 30 s d'étalement). Si le réseau n'est pas encore là, le script attend et réessaie
  chaque minute sans rien lancer.
- **`--continue` réussit** (arrêt de moins d'environ 4 h, session encore connue du serveur) : **même session claude.ai**,
  même conversation. Le serveur est alors en mode « session unique » ; quand la session se termine, il s'arrête et le
  minuteur le relance une minute plus tard.
- **rien à reprendre** (« No recent session found », par exemple après plus de 4 h) : **pas de nouvelle session** avec le
  `RC_FALLBACK=never` par défaut (code 7, journalisé avec la commande à lancer) ; avec `norecord`, une nouvelle session de
  même nom. L'ancienne reste « hors ligne » dans claude.ai/code : à archiver.
- **la session est déjà servie** par un autre processus : **pas de nouvelle session**, code 5.
- **erreur inconnue** (réseau, serveur…) : **pas de nouvelle session**, code 6, le message est journalisé ; le minuteur
  réessaie (au plus 3 lancements par 10 minutes). Si la session est définitivement perdue : `claude-rc-ctl fresh <id> --yes`.
- **la connexion Claude expire** : rien n'est lancé, une erreur claire est journalisée et le service échoue
  (`systemctl --user --failed`). Refaire `claude auth login`.
- **la mémoire disponible est basse** : rien de nouveau n'est lancé (code 8) ; les sessions déjà en cours ne sont pas touchées.
- **plusieurs instances** : chacune a son `<id>.env`, sa session tmux (`rc-<id>`), son journal, son verrou et son compteur.

## Dossier de travail, `CLAUDE.md` et accès aux autres dossiers

- Claude Code charge le `CLAUDE.md` de chaque dossier parent du dossier de travail : une session lancée dans un sous-dossier
  d'un dépôt reçoit le `CLAUDE.md` du dépôt **et** `~/CLAUDE.md` (vérifié).
- Sous `acceptEdits`, une session n'écrit sans demander **que dans son dossier de travail et ses dossiers additionnels** ;
  lire ou écrire ailleurs est refusé (mode sans terminal) ou demande confirmation (interactif). `claude remote-control` n'a
  **aucune option `--add-dir`** : déclarer les dossiers dans un fichier de réglages —
  `~/.claude/settings.json` (toutes les sessions de l'utilisateur) ou `<dossier de travail>/.claude/settings.local.json`
  (un seul dossier) :
  ```json
  { "permissions": { "additionalDirectories": ["/home/moi/projects"] } }
  ```
  Vérifié : sans cela l'écriture dans un projet voisin était refusée ; avec, la lecture et l'écriture fonctionnaient (voir
  [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md)). Attention : `<dossier>/.claude/` peut être suivi par git : vérifier le `.gitignore`.
- Le `CLAUDE.md` d'un dossier additionnel n'est chargé que si `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` (set to `1`).

## Sécurité

- Aucun droit administrateur, aucun port ouvert : Remote Control ne fait que des connexions **sortantes**.
- Aucun secret dans ce dépôt ni dans les fichiers de configuration ; la connexion est celle de `claude auth login`
  (`~/.claude/.credentials.json`, droits 600) : ces scripts **ne lisent jamais ce fichier** et n'appellent que `claude auth status`.
- Modes de permission autorisés : `default`, `acceptEdits`, `plan`. **`bypassPermissions`, `auto` et `dontAsk` sont refusés**
  par le script. Une session pilotée à distance peut exécuter des commandes sur la machine avec les droits du compte :
  choisir en conséquence le dossier de travail, les dossiers additionnels et le compte.
- `<id>.env` est chargé comme du code shell : il doit appartenir à l'utilisateur et n'être modifiable que par lui (600).
- Les fichiers d'état sont en 600 dans un dossier 700, quel que soit l'`umask`. L'`umask` normal est conservé pour tmux et claude.

## Limites connues

- **Une instance = un dossier de travail = un nom de session**, uniques (`--continue` est lié au dossier). Deux instances
  dans des dossiers imbriqués (l'un dans un sous-dossier de l'autre) sont distinctes pour cet outil, mais cela n'a pas été
  testé avec deux vrais serveurs.
- Après une reprise le serveur est en mode **« session unique »** : pas de nouvelles sessions depuis le téléphone.
- Avec `KillMode=process`, tmux et claude restent dans le cgroup du service terminé, et systemd journalise des avertissements
  « Found left-over process … Ignoring » à chaque passage. Sans gravité mais bruyant ; une conception plus propre est prévue.
- Mémoire : environ **370 Mo** par session au repos (serveur + enfant), mesurés une fois ; une session qui travaille en
  consomme davantage. Rien ne limite le nombre d'instances sauf `RC_MIN_AVAILABLE_MB` : dimensionner la machine (et le swap).
- Linux uniquement (`/proc`, `flock`, `stat`/`readlink` GNU).
- La fenêtre de reprise d'environ 4 h et un redémarrage avec réseau tardif ne sont **pas vérifiés**.

## Tests

```bash
bash tests/run-tests.sh          # sous Linux (ou WSL) ; environ 170 contrôles
```

Les tests utilisent de faux `claude`, `tmux`, `curl`, `pgrep` et `systemctl`, et un faux `/proc` : ils ne touchent ni le
réseau ni une vraie session. Ils ne remplacent pas un vrai test (voir [docs/VERIFIED.fr.md](docs/VERIFIED.fr.md)). Sous
Windows (Git Bash), les tests de droits et de verrou sont ignorés.

**Avant de publier un fork ou une contribution :** `bash tests/hygiene.sh` cherche clés, adresses IPv4, e-mails et longues
chaînes aléatoires. Pour ajouter vos propres termes à ne jamais publier (noms, projets, hôtes), créer
`tests/private-patterns.local` (un motif par ligne). Ce fichier est dans `.gitignore` et ne doit **jamais** être versionné.

## Licence

MIT (voir [LICENSE](LICENSE)).

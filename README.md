# Docker Volume Manager

Script Bash de gestion des volumes Docker permettant :

- la sauvegarde de volumes Docker
- la restauration d'archives dans un volume Docker
- le listing des sauvegardes locales
- le listing des sauvegardes distantes via SFTP
- la gestion de la rétention locale et distante
- le mode `hot backup` ou `stop/start` des conteneurs
- la suppression optionnelle des sauvegardes locales après transfert distant

## 📋 Sommaire

- [Arborescence du projet](#arborscence-du-projet)
- [Fonctionnalités](#fonctionnalits)
- [Prérequis](#prrequis)
- [Installation](#installation)
- [Fichier de configuration](#fichier-de-configuration)
- [Gestion des exclusions](#gestion-des-exclusions)
- [Utilisation](#utilisation)
- [Modes de sauvegarde](#modes-de-sauvegarde)
- [Politique de rétention](#politique-de-rtention)
- [Logs](#logs)
- [Sécurité](#scurit)
- [Bonnes pratiques](#bonnes-pratiques)
- [Exemples de workflow](#exemples-de-workflow)
- [Limites actuelles](#limites-actuelles)
- [Évolutions possibles](#volutions-possibles)
- [Licence](#licence)

---

## Arborescence du projet

```bash
/opt/docker/newbackups/
├── archive/                         # Archives locales .tar.gz
├── log/                             # Fichiers de logs
└── script/
    ├── docker-volume-manager.sh     # Script principal
    ├── .env                         # Configuration
    └── exclude.txt                  # Volumes exclus du mode --all
```

## Fonctionnalités

Le script gère 4 actions principales :
- **backup** : sauvegarde de un ou plusieurs volumes Docker
- **restore** : restauration d'une archive dans un volume Docker
- **list-local** : liste des sauvegardes locales disponibles
- **list-sftp** : liste des sauvegardes disponibles sur le serveur SFTP

## Prérequis

Le script nécessite les commandes suivantes :
- `docker`
- `tar`
- `find`
- `stat`
- `date`
- `du`
- `flock`

Pour les fonctionnalités distantes SFTP : `sftp`

## Installation

```bash
# Créer la structure, par exemple :
sudo mkdir -p /opt/docker/backups/{archive,log,script}

# Copier les fichiers
sudo cp docker-volume-manager.sh /opt/docker/backups/script/
sudo cp exemple.env /opt/docker/backups/script/.env
sudo cp exclude.txt /opt/docker/backups/script/

# Permissions
sudo chmod +x /opt/docker/backups/script/docker-volume-manager.sh
sudo chown -R root:root /opt/docker/backups/
```

## Fichier de configuration

Le fichier `.env` doit être présent dans le dossier `script/`.

**Exemple de configuration :**

```bash
BACKUP_DIR="/opt/docker/backups/archive"
EXCLUDE_FILE="/opt/docker/backups/script/exclude.txt"

BACKUP_LOG_FILE="/opt/docker/backups/log/backup.log"
LOG_MAX_SIZE_MB=10
LOG_MAX_ROTATE=5

LOCAL_RETENTION_DAYS=3
SFTP_RETENTION_DAYS=15

DATE_FORMAT="%Y%m%d_%H%M"
DEFAULT_BACKUP_MODE="stop"
DRY_RUN=false
KEEP_LOCAL_BACKUP=true

REMOTE_ENABLED=true
REMOTE_METHOD="sftp"

SFTP_HOST="10.10.10.10"
SFTP_PORT=22
SFTP_USER="backupdocker"
SFTP_REMOTE_DIR="/docker-backup-01"
SFTP_SSH_KEY="/root/.ssh/id_ed255"
SFTP_TIMEOUT=30
```

## Gestion des exclusions

Le fichier `exclude.txt` contient la liste des volumes à exclure lorsque l'option `--all` est utilisée.

**Exemple :**
portainer_data
registry_data
test_volume


## Utilisation

Le script doit être exécuté depuis le dossier `script/` ou avec son chemin complet.

### Aide
```bash
./docker-volume-manager.sh --help
```

### Sauvegarde

```bash
# Sauvegarder tous les volumes
./docker-volume-manager.sh backup --all

# Sauvegarder tous les volumes en hot backup
./docker-volume-manager.sh backup --all --hot

# Sauvegarder un volume spécifique
./docker-volume-manager.sh backup --volume wiki_data

# Sauvegarder plusieurs volumes
./docker-volume-manager.sh backup --volume wiki_data --volume db_data

# Sauvegarder avec transfert distant SFTP
./docker-volume-manager.sh backup --all --remote --remote-method sftp

# Sauvegarder sans conserver la copie locale après transfert
./docker-volume-manager.sh backup --all --remote --remote-method sftp --no-keep-local

# Simulation sans exécution réelle
./docker-volume-manager.sh backup --all --dry-run
```

### Listing des sauvegardes

```bash
# Liste des sauvegardes locales
./docker-volume-manager.sh list-local

# Liste des sauvegardes distantes SFTP
./docker-volume-manager.sh list-sftp
```

### Restauration

```bash
# Restaurer une archive locale dans un volume
./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source local

# Restaurer une archive distante SFTP dans un volume
./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source sftp

# Restaurer en vidant le volume avant extraction
./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source sftp --wipe-volume

# Simulation d'une restauration
./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source local --dry-run
```

## Modes de sauvegarde

Le script supporte deux modes :

| Mode | Commande | Description |
|------|----------|-------------|
| **stop** | `--stop` | Arrête les conteneurs, sauvegarde, redémarre |
| **hot** | `--hot` | Sauvegarde sans arrêter les conteneurs |

```bash
./docker-volume-manager.sh backup --volume wiki_data --stop
./docker-volume-manager.sh backup --volume wiki_data --hot
```

## Politique de rétention

Le script distingue deux politiques de rétention :

| Type | Durée | Objectif |
|------|-------|----------|
| **Locale** | 3 jours | Limiter espace disque |
| **SFTP** | 15 jours | Historique long terme |

## Politique de conservation locale

Contrôlée par :
- `KEEP_LOCAL_BACKUP=true` (fichier `.env`)
- `--keep-local` / `--no-keep-local` (CLI)

**Exemple sans conservation locale :**
```bash
./docker-volume-manager.sh backup --all --remote --no-keep-local
```

## Logs

Les logs sont stockés dans : `/opt/docker/newbackups/log/`

Rotation automatique par taille :
backup.log
backup.log.1
backup.log.2

**Variables :**
LOG_MAX_SIZE_MB=10
LOG_MAX_ROTATE=5


## Sécurité

Le script applique plusieurs mécanismes de sécurité :

- ✅ Verrou d'exécution avec `flock`
- ✅ Validation des paramètres
- ✅ Validation des volumes Docker
- ✅ Redémarrage des conteneurs via `trap`
- ✅ Mode `dry-run`
- ✅ Permissions renforcées via `umask 077`

## Bonnes pratiques

- [ ] Tester les commandes avec `--dry-run` avant exécution réelle
- [ ] Vérifier régulièrement la restauration d'un backup
- [ ] Conserver une rétention distante plus longue que locale
- [ ] Utiliser `--wipe-volume` avec prudence
- [ ] Protéger strictement la clé SSH SFTP

## Exemples de workflow

```bash
# 1. Sauvegarde quotidienne avec conservation locale
./docker-volume-manager.sh backup --all --remote --keep-local

# 2. Sauvegarde quotidienne sans conservation locale
./docker-volume-manager.sh backup --all --remote --no-keep-local

# 3. Vérification des archives
./docker-volume-manager.sh list-local
./docker-volume-manager.sh list-sftp

# 4. Test de restauration
./docker-volume-manager.sh restore --volume test_restore --archive wiki_data_20260410_1200.tar.gz --source local --dry-run
```

## Limites actuelles

**Version actuelle :**
- Transport distant : `sftp` uniquement
- Format : `.tar.gz`
- Rétention SFTP : basée sur date dans nom fichier
- Environnement : Linux + Docker

## Licence

**Usage interne ou privé autorisé.**  
Toute redistribution, modification ou utilisation publique doit mentionner explicitement l'auteur.

**Auteur** : Luciano Sautron

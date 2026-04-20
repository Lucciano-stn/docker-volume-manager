
#!/usr/bin/env bash
# backup_volumes.sh - Backup / Restore Docker volumes
#
# Auteur       : Luciano Sautron
# Année        : 2026
#
# Description  :
#   Outil de gestion des sauvegardes Docker avec :
#   - backup de volumes Docker
#   - restauration de volumes Docker
#   - listing des archives locales et SFTP
#   - mode stop/start ou hot backup
#   - logs rotatifs
#   - rétention locale et distante
#   - transport distant abstrait (SFTP pour l’instant)
#
# Usage :
#   ./docker-volume-manager.sh backup --all
#   ./docker-volume-manager.sh backup --volume vol1 --remote
#   ./docker-volume-manager.sh restore --volume vol1 --archive vol1_20260410_1200.tar.gz --source local
#   ./docker-volume-manager.sh list-local
#   ./docker-volume-manager.sh list-sftp
#
# Version : 1.2.0
# Dernière mise à jour : 2026-04-10

set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

DATE=""
LOCK_FILE="/tmp/backup_volumes.lock"

ACTION=""

declare -a VOLUMES=()
declare -a STOPPED_CONTAINERS=()
declare -a INVALID_VOLUMES=()
declare -a FAILED_LOCAL_VOLUMES=()
declare -a FAILED_REMOTE_VOLUMES=()
declare -a SUCCESS_LOCAL_VOLUMES=()
declare -a SUCCESS_REMOTE_VOLUMES=()

BACKUP_ALL=false
BACKUP_MODE=""
REMOTE_ENABLED=""
REMOTE_METHOD=""
DRY_RUN=""
KEEP_LOCAL_BACKUP=""

LOCAL_RETENTION_DAYS=""
SFTP_RETENTION_DAYS=""

BACKUP_DIR=""
EXCLUDE_FILE=""
BACKUP_LOG_FILE=""
LOG_MAX_SIZE_MB=""
LOG_MAX_ROTATE=""
DATE_FORMAT=""

RESTORE_SOURCE="local"     # local | sftp
RESTORE_ARCHIVE=""
WIPE_VOLUME=false

SUCCESS_COUNT_LOCAL=0
SUCCESS_COUNT_REMOTE=0

# =========================================================
# AIDE
# =========================================================
show_help() {
    cat << 'EOF'
NAME
    docker-volume-manager.sh - Backup / Restore volumes Docker

SYNOPSIS
    ./docker-volume-manager.sh backup --all
    ./docker-volume-manager.sh backup --all --hot
    ./docker-volume-manager.sh backup --volume vol1 --volume vol2
    ./docker-volume-manager.sh backup --all --remote --remote-method sftp

    ./docker-volume-manager.sh restore --volume vol1 --archive fichier.tar.gz --source local
    ./docker-volume-manager.sh restore --volume vol1 --archive fichier.tar.gz --source sftp
    ./docker-volume-manager.sh restore --volume vol1 --archive fichier.tar.gz --source sftp --wipe-volume

    ./docker-volume-manager.sh list-local
    ./docker-volume-manager.sh list-sftp
    ./docker-volume-manager.sh --help

DESCRIPTION
    Outil de sauvegarde et restauration de volumes Docker.

ACTIONS
    backup
        Sauvegarde un ou plusieurs volumes Docker

    restore
        Restaure une archive dans un volume Docker

    list-local
        Liste les backups locaux disponibles

    list-sftp
        Liste les backups SFTP disponibles

OPTIONS BACKUP
    --all
        Sauvegarde tous les volumes locaux Docker (hors exclude.txt)

    --volume, -v NOM
        Ajoute un volume spécifique à sauvegarder
        Option répétable

    --hot, --hotbackup, -hb
        Sauvegarde à chaud, sans arrêt des containers

    --stop
        Sauvegarde avec arrêt/reprise des containers

    --remote
        Force l’envoi distant

    --no-remote
        Désactive l’envoi distant

    --remote-method METHODE
        Méthode distante à utiliser
        Valeurs supportées : sftp, none

    --keep-local
        Conserve la copie locale après sauvegarde

    --no-keep-local
        Supprime la copie locale après sauvegarde réussie

    --retention-local JOURS
        Surcharge la rétention locale

    --retention-sftp JOURS
        Surcharge la rétention SFTP

    --dry-run
        Mode simulation, aucune action destructive

OPTIONS RESTORE
    --volume, -v NOM
        Volume cible à restaurer

    --archive NOM_FICHIER
        Nom de l’archive à restaurer

    --source SOURCE
        Source de l’archive : local | sftp
        Défaut : local

    --wipe-volume
        Vide le volume avant restauration

    --dry-run
        Mode simulation

OPTIONS GÉNÉRALES
    --help, -h, man
        Affiche cette aide

EXEMPLES
    ./docker-volume-manager.sh --all
    ./docker-volume-manager.sh backup --all --hot
    ./docker-volume-manager.sh backup --volume 001-prod-elaguila-wp-primary
    ./docker-volume-manager.sh backup --volume 001-prod-a --volume 001-prod-b --remote

    ./docker-volume-manager.sh list-local
    ./docker-volume-manager.sh list-sftp

    ./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source local
    ./docker-volume-manager.sh restore --volume wiki_data --archive wiki_data_20260410_1200.tar.gz --source sftp --wipe-volume
EOF
    exit 0
}

# =========================================================
# OUTILS
# =========================================================
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ Commande requise absente: $1"
        exit 3
    }
}

bool_normalize() {
    case "${1,,}" in
        true|yes|1) echo "true" ;;
        false|no|0) echo "false" ;;
        *)
            echo "❌ Valeur booléenne invalide: $1" >&2
            exit 2
            ;;
    esac
}

run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

rotate_log() {
    local max_size max_rotate current_size i
    max_size=$((LOG_MAX_SIZE_MB * 1024 * 1024))
    max_rotate="$LOG_MAX_ROTATE"
    current_size=$(stat -c%s "$BACKUP_LOG_FILE" 2>/dev/null || echo 0)

    if [ "$current_size" -ge "$max_size" ]; then
        [ -f "$BACKUP_LOG_FILE.$max_rotate" ] && rm -f "$BACKUP_LOG_FILE.$max_rotate"

        for ((i=max_rotate-1; i>=1; i--)); do
            [ -f "$BACKUP_LOG_FILE.$i" ] && mv "$BACKUP_LOG_FILE.$i" "$BACKUP_LOG_FILE.$((i+1))"
        done

        [ -f "$BACKUP_LOG_FILE" ] && mv "$BACKUP_LOG_FILE" "$BACKUP_LOG_FILE.1"
        touch "$BACKUP_LOG_FILE"
        echo "=== LOG ROTATED $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$BACKUP_LOG_FILE"
    fi
}

log() {
    local msg ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[$ts] $*"

    rotate_log
    echo "$msg"
    echo "$msg" >> "$BACKUP_LOG_FILE" 2>/dev/null
}

# =========================================================
# CHARGEMENT CONFIG
# =========================================================
load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ Fichier .env introuvable: $ENV_FILE"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$ENV_FILE"

    : "${BACKUP_DIR:?Variable BACKUP_DIR manquante}"
    : "${EXCLUDE_FILE:?Variable EXCLUDE_FILE manquante}"
    : "${BACKUP_LOG_FILE:?Variable BACKUP_LOG_FILE manquante}"
    : "${LOG_MAX_SIZE_MB:?Variable LOG_MAX_SIZE_MB manquante}"
    : "${LOG_MAX_ROTATE:?Variable LOG_MAX_ROTATE manquante}"
    : "${LOCAL_RETENTION_DAYS:?Variable LOCAL_RETENTION_DAYS manquante}"
    : "${SFTP_RETENTION_DAYS:?Variable SFTP_RETENTION_DAYS manquante}"
    : "${DATE_FORMAT:?Variable DATE_FORMAT manquante}"
    : "${DEFAULT_BACKUP_MODE:?Variable DEFAULT_BACKUP_MODE manquante}"
    : "${DRY_RUN:?Variable DRY_RUN manquante}"
    : "${REMOTE_ENABLED:?Variable REMOTE_ENABLED manquante}"
    : "${REMOTE_METHOD:?Variable REMOTE_METHOD manquante}"
    : "${KEEP_LOCAL_BACKUP:?Variable KEEP_LOCAL_BACKUP manquante}"

    DRY_RUN="$(bool_normalize "$DRY_RUN")"
    REMOTE_ENABLED="$(bool_normalize "$REMOTE_ENABLED")"
    KEEP_LOCAL_BACKUP="$(bool_normalize "$KEEP_LOCAL_BACKUP")"

    mkdir -p "$(dirname "$BACKUP_LOG_FILE")"
    mkdir -p "$BACKUP_DIR"
    [ -f "$EXCLUDE_FILE" ] || touch "$EXCLUDE_FILE"

    if [ "$KEEP_LOCAL_BACKUP" = "false" ] && [ "$REMOTE_ENABLED" != "true" ]; then
        log "⚠️ KEEP_LOCAL_BACKUP=false mais remote désactivé: la copie locale sera conservée"
    fi

    DATE="$(date +"$DATE_FORMAT")"
}

set_defaults() {
    BACKUP_MODE="$DEFAULT_BACKUP_MODE"
}

# =========================================================
# PARSING DES ACTIONS
# =========================================================
parse_action() {
    if [ $# -eq 0 ]; then
        show_help
    fi

    case "$1" in
        backup|restore|list-local|list-sftp)
            ACTION="$1"
            shift
            ;;
        --help|-h|man)
            show_help
            ;;
        *)
            echo "❌ Action inconnue: $1"
            show_help
            ;;
    esac

    parse_args "$@"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                BACKUP_ALL=true
                shift
                ;;
            --volume|-v)
                [ $# -lt 2 ] && { echo "❌ --volume nécessite un nom"; exit 2; }
                VOLUMES+=("$2")
                shift 2
                ;;
            --hot|--hotbackup|-hb)
                BACKUP_MODE="hot"
                shift
                ;;
            --stop)
                BACKUP_MODE="stop"
                shift
                ;;
            --remote)
                REMOTE_ENABLED="true"
                shift
                ;;
            --no-remote)
                REMOTE_ENABLED="false"
                shift
                ;;
            --remote-method)
                [ $# -lt 2 ] && { echo "❌ --remote-method nécessite une valeur"; exit 2; }
                REMOTE_METHOD="$2"
                shift 2
                ;;
            --keep-local)
                KEEP_LOCAL_BACKUP="true"
                shift
                ;;
            --no-keep-local)
                KEEP_LOCAL_BACKUP="false"
                shift
                ;;
            --retention-local)
                [ $# -lt 2 ] && { echo "❌ --retention-local nécessite une valeur"; exit 2; }
                LOCAL_RETENTION_DAYS="$2"
                shift 2
                ;;
            --retention-sftp)
                [ $# -lt 2 ] && { echo "❌ --retention-sftp nécessite une valeur"; exit 2; }
                SFTP_RETENTION_DAYS="$2"
                shift 2
                ;;
            --archive)
                [ $# -lt 2 ] && { echo "❌ --archive nécessite une valeur"; exit 2; }
                RESTORE_ARCHIVE="$2"
                shift 2
                ;;
            --source)
                [ $# -lt 2 ] && { echo "❌ --source nécessite une valeur"; exit 2; }
                RESTORE_SOURCE="$2"
                shift 2
                ;;
            --wipe-volume)
                WIPE_VOLUME=true
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --help|-h|man)
                show_help
                ;;
            -*)
                echo "❌ Option inconnue: $1"
                exit 2
                ;;
            *)
                echo "❌ Argument inattendu: $1"
                exit 2
                ;;
        esac
    done
}

# =========================================================
# VALIDATION
# =========================================================
validate_common_config() {
    if ! [[ "$LOCAL_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        echo "❌ LOCAL_RETENTION_DAYS doit être un entier positif"
        exit 2
    fi

    if ! [[ "$SFTP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        echo "❌ SFTP_RETENTION_DAYS doit être un entier positif"
        exit 2
    fi

    require_cmd docker
    require_cmd tar
    require_cmd find
    require_cmd stat
    require_cmd date
    require_cmd du
    require_cmd flock
}

validate_remote_config() {
    case "$REMOTE_METHOD" in
        sftp|none) ;;
        *)
            echo "❌ REMOTE_METHOD invalide: $REMOTE_METHOD"
            exit 2
            ;;
    esac

    if [ "$REMOTE_ENABLED" != "true" ]; then
        REMOTE_METHOD="none"
        return 0
    fi

    case "$REMOTE_METHOD" in
        sftp)
            require_cmd sftp
            : "${SFTP_HOST:?Variable SFTP_HOST manquante}"
            : "${SFTP_PORT:?Variable SFTP_PORT manquante}"
            : "${SFTP_USER:?Variable SFTP_USER manquante}"
            : "${SFTP_REMOTE_DIR:?Variable SFTP_REMOTE_DIR manquante}"
            : "${SFTP_SSH_KEY:?Variable SFTP_SSH_KEY manquante}"
            : "${SFTP_TIMEOUT:?Variable SFTP_TIMEOUT manquante}"

            if [ ! -f "$SFTP_SSH_KEY" ]; then
                echo "❌ Clé SSH SFTP introuvable: $SFTP_SSH_KEY"
                exit 2
            fi
            ;;
    esac
}

validate_backup_config() {
    case "$BACKUP_MODE" in
        stop|hot) ;;
        *)
            echo "❌ BACKUP_MODE invalide: $BACKUP_MODE"
            exit 2
            ;;
    esac

    validate_common_config
    validate_remote_config

    if [ "$BACKUP_ALL" = false ] && [ ${#VOLUMES[@]} -eq 0 ]; then
        echo "❌ En mode backup, utilisez --all ou --volume NOM"
        exit 2
    fi
}

validate_restore_config() {
    validate_common_config
    validate_remote_config

    case "$RESTORE_SOURCE" in
        local|sftp) ;;
        *)
            echo "❌ --source invalide: $RESTORE_SOURCE (valeurs: local | sftp)"
            exit 2
            ;;
    esac

    if [ ${#VOLUMES[@]} -ne 1 ]; then
        echo "❌ En mode restore, un seul --volume est requis"
        exit 2
    fi

    if [ -z "$RESTORE_ARCHIVE" ]; then
        echo "❌ En mode restore, --archive est requis"
        exit 2
    fi

    if [ "$RESTORE_SOURCE" = "sftp" ] && [ "$REMOTE_ENABLED" != "true" -o "$REMOTE_METHOD" != "sftp" ]; then
        echo "❌ La restauration SFTP nécessite REMOTE_ENABLED=true et REMOTE_METHOD=sftp"
        exit 2
    fi
}

validate_list_sftp_config() {
    validate_common_config
    validate_remote_config

    if [ "$REMOTE_ENABLED" != "true" -o "$REMOTE_METHOD" != "sftp" ]; then
        echo "❌ list-sftp nécessite REMOTE_ENABLED=true et REMOTE_METHOD=sftp"
        exit 2
    fi
}

# =========================================================
# VERROU
# =========================================================
acquire_lock() {
    exec 9>"$LOCK_FILE"
    flock -n 9 || {
        echo "❌ Un backup/restore est déjà en cours"
        exit 1
    }
}

# =========================================================
# VOLUMES
# =========================================================
resolve_volumes_for_backup() {
    local vol
    local -a all_volumes=()
    local -a valid_volumes=()

    if [ "$BACKUP_ALL" = true ]; then
        mapfile -t all_volumes < <(
            docker volume ls -q --filter driver=local | grep -v -f "$EXCLUDE_FILE" | sort
        )
        VOLUMES=("${all_volumes[@]}")
        log "🌐 Mode tous volumes: ${#VOLUMES[@]} volume(s) détecté(s)"
    fi

    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            valid_volumes+=("$vol")
        else
            INVALID_VOLUMES+=("$vol")
            log "❌ Volume inexistant: $vol"
        fi
    done

    VOLUMES=("${valid_volumes[@]}")

    if [ ${#VOLUMES[@]} -eq 0 ]; then
        log "🚫 Aucun volume valide à sauvegarder"
        exit 4
    fi

    log "✅ ${#VOLUMES[@]} volume(s) valide(s)"
}

validate_restore_volume() {
    local volume="$1"

    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
        log "❌ Volume cible introuvable: $volume"
        exit 4
    fi
}

# =========================================================
# CONTAINERS
# =========================================================
stop_containers_for_volume() {
    local volume="$1"
    local containers

    containers="$(docker ps -q --filter volume="$volume")"

    if [ -z "$containers" ]; then
        log "   ℹ️ Aucun container actif lié au volume $volume"
        return 0
    fi

    log "   ⏹️ Arrêt des containers pour $volume : $containers"

    if run_cmd docker stop $containers >/dev/null 2>&1; then
        STOPPED_CONTAINERS+=($containers)
        sleep 2
        return 0
    fi

    log "   ⚠️ docker stop a échoué, tentative docker kill"
    if run_cmd docker kill $containers >/dev/null 2>&1; then
        STOPPED_CONTAINERS+=($containers)
        sleep 2
        return 0
    fi

    log "   ❌ Impossible d’arrêter les containers pour $volume"
    return 1
}

restart_stopped_containers() {
    local cid

    [ ${#STOPPED_CONTAINERS[@]} -eq 0 ] && return 0

    log "🔁 Redémarrage des containers arrêtés par le script"

    for cid in "${STOPPED_CONTAINERS[@]}"; do
        if run_cmd docker start "$cid" >/dev/null 2>&1; then
            log "   ▶️ Restart OK: $cid"
        else
            log "   ❌ Restart KO: $cid"
        fi
    done

    STOPPED_CONTAINERS=()
}

cleanup_on_exit() {
    restart_stopped_containers
}

# =========================================================
# BACKUP LOCAL
# =========================================================
create_local_backup() {
    local volume="$1"
    local backup_file="$2"
    local archive_path="$BACKUP_DIR/$backup_file"
    local size

    log "   💾 Création archive: $backup_file"

    if [ "$DRY_RUN" = "true" ]; then
        log "   [DRY-RUN] docker run --rm -v $volume:/data:ro -v $BACKUP_DIR:/backup alpine tar czf /backup/$backup_file -C /data ."
        return 0
    fi

    if docker run --rm \
        -v "$volume":/data:ro \
        -v "$BACKUP_DIR":/backup \
        alpine \
        sh -c "tar czf \"/backup/$backup_file\" -C /data ." >/dev/null 2>&1 && [ -s "$archive_path" ]; then

        size=$(du -h "$archive_path" | cut -f1)
        log "   ✅ Backup local OK ($size)"
        return 0
    fi

    rm -f "$archive_path" 2>/dev/null
    log "   ❌ Échec backup local"
    return 1
}

# =========================================================
# REMOTE ABSTRAIT
# =========================================================
send_remote() {
    local file="$1"

    if [ "$REMOTE_ENABLED" != "true" ]; then
        log "   ℹ️ Envoi distant désactivé"
        return 10
    fi

    case "$REMOTE_METHOD" in
        sftp)
            send_remote_sftp "$file"
            ;;
        none)
            log "   ℹ️ REMOTE_METHOD=none"
            return 10
            ;;
        *)
            log "   ❌ Méthode remote non supportée: $REMOTE_METHOD"
            return 1
            ;;
    esac
}

cleanup_remote() {
    if [ "$REMOTE_ENABLED" != "true" ]; then
        log "ℹ️ Rotation remote désactivée"
        return 0
    fi

    case "$REMOTE_METHOD" in
        sftp)
            cleanup_remote_sftp
            ;;
        none)
            log "ℹ️ Rotation remote ignorée (REMOTE_METHOD=none)"
            return 0
            ;;
        *)
            log "❌ Méthode remote non supportée pour cleanup: $REMOTE_METHOD"
            return 1
            ;;
    esac
}

# =========================================================
# SFTP
# =========================================================
send_remote_sftp() {
    local local_file="$1"
    local remote_file sftp_target sftp_output sftp_rc

    remote_file="$(basename "$local_file")"
    sftp_target="${SFTP_USER}@${SFTP_HOST}"

    if [ ! -f "$local_file" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log "   [DRY-RUN] Envoi SFTP : $local_file"
            return 0
        else
            log "   ❌ Fichier local introuvable pour envoi SFTP: $local_file"
            return 1
        fi
    fi

    log "   📤 Envoi SFTP vers ${sftp_target}:${SFTP_REMOTE_DIR}/${remote_file}"

    if [ "$DRY_RUN" = "true" ]; then
        log "   [DRY-RUN] put $local_file ${SFTP_REMOTE_DIR}/${remote_file}"
        return 0
    fi

    sftp_output=$(
        sftp -b - \
            -i "${SFTP_SSH_KEY}" \
            -P "${SFTP_PORT}" \
            -o BatchMode=yes \
            -o ConnectTimeout="${SFTP_TIMEOUT}" \
            -o StrictHostKeyChecking=accept-new \
            "${sftp_target}" 2>&1 <<EOF
cd "${SFTP_REMOTE_DIR}"
put "${local_file}" "${remote_file}"
ls -l "${remote_file}"
EOF
    )
    sftp_rc=$?

    if [ "$sftp_rc" -eq 0 ]; then
        log "   ✅ Transfert SFTP OK: ${remote_file}"
        return 0
    fi

    log "   ❌ Échec transfert SFTP: ${remote_file}"
    log "   🔎 Détail SFTP: ${sftp_output}"
    return 1
}

list_sftp_backups() {
    local remote_dir remote_files

    remote_dir="${SFTP_REMOTE_DIR%/}"

    remote_files=$(
        sftp -b - \
            -i "${SFTP_SSH_KEY}" \
            -P "${SFTP_PORT}" \
            -o BatchMode=yes \
            -o ConnectTimeout="${SFTP_TIMEOUT}" \
            -o StrictHostKeyChecking=accept-new \
            "${SFTP_USER}@${SFTP_HOST}" 2>/dev/null <<EOF
cd "${remote_dir}"
ls -1
EOF
    )

    if [ $? -ne 0 ]; then
        log "❌ Impossible de lister ${remote_dir} sur le SFTP"
        return 1
    fi

    if [ -z "$remote_files" ]; then
        log "ℹ️ Aucun backup distant trouvé"
        return 0
    fi

    echo "$remote_files" | grep '\.tar\.gz$' | sort || true
}

download_sftp_backup() {
    local archive_name="$1"
    local tmp_dir="$2"
    local remote_dir local_path

    remote_dir="${SFTP_REMOTE_DIR%/}"
    local_path="${tmp_dir}/${archive_name}"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] get ${remote_dir}/${archive_name} ${local_path}"
        return 0
    fi

    sftp -b - \
        -i "${SFTP_SSH_KEY}" \
        -P "${SFTP_PORT}" \
        -o BatchMode=yes \
        -o ConnectTimeout="${SFTP_TIMEOUT}" \
        -o StrictHostKeyChecking=accept-new \
        "${SFTP_USER}@${SFTP_HOST}" >/dev/null 2>&1 <<EOF
cd "${remote_dir}"
get "${archive_name}" "${local_path}"
EOF

    [ -f "$local_path" ]
}

cleanup_remote_sftp() {
    local remote_dir remote_files old_remote_count tmp_batch
    local file file_date file_epoch now_epoch limit_seconds age_seconds

    remote_dir="${SFTP_REMOTE_DIR%/}"
    old_remote_count=0
    tmp_batch="$(mktemp)"

    if [ "$DRY_RUN" = "true" ]; then
        log "ℹ️ [DRY-RUN] Rotation remote SFTP simulée sur ${remote_dir}"
        rm -f "$tmp_batch"
        return 0
    fi

    remote_files=$(
        sftp -b - \
            -i "${SFTP_SSH_KEY}" \
            -P "${SFTP_PORT}" \
            -o BatchMode=yes \
            -o ConnectTimeout="${SFTP_TIMEOUT}" \
            -o StrictHostKeyChecking=accept-new \
            "${SFTP_USER}@${SFTP_HOST}" 2>/dev/null <<EOF
cd "${remote_dir}"
ls -1
EOF
    )

    if [ $? -ne 0 ]; then
        log "❌ Rotation remote SFTP: impossible de lister ${remote_dir}"
        rm -f "$tmp_batch"
        return 1
    fi

    now_epoch=$(date +%s)
    limit_seconds=$((SFTP_RETENTION_DAYS * 86400))

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        case "$file" in
            *.tar.gz) ;;
            *) continue ;;
        esac

        file_date="$(echo "$file" | grep -oE '[0-9]{8}_[0-9]{4}' | tail -1)"
        [ -z "$file_date" ] && continue

        file_epoch=$(date -d "${file_date:0:4}-${file_date:4:2}-${file_date:6:2} ${file_date:9:2}:${file_date:11:2}:00" +%s 2>/dev/null)
        [ -z "$file_epoch" ] && continue

        age_seconds=$((now_epoch - file_epoch))

        if [ "$age_seconds" -gt "$limit_seconds" ]; then
            echo "rm \"${remote_dir}/${file}\"" >> "$tmp_batch"
            old_remote_count=$((old_remote_count + 1))
        fi
    done <<< "$remote_files"

    if [ "$old_remote_count" -gt 0 ]; then
        sftp -b "$tmp_batch" \
            -i "${SFTP_SSH_KEY}" \
            -P "${SFTP_PORT}" \
            -o BatchMode=yes \
            -o ConnectTimeout="${SFTP_TIMEOUT}" \
            -o StrictHostKeyChecking=accept-new \
            "${SFTP_USER}@${SFTP_HOST}" >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            log "🧹 Rotation remote SFTP: $old_remote_count fichier(s) supprimé(s) sur ${remote_dir} (rétention $SFTP_RETENTION_DAYS jours)"
        else
            log "❌ Rotation remote SFTP: échec suppression de $old_remote_count fichier(s)"
            rm -f "$tmp_batch"
            return 1
        fi
    else
        log "ℹ️ Rotation remote SFTP: aucun backup à supprimer"
    fi

    rm -f "$tmp_batch"
    return 0
}

# =========================================================
# LISTING LOCAL
# =========================================================
list_local_backups() {
    local -a files=()

    mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.tar.gz" -printf "%f\n" | sort)

    if [ ${#files[@]} -eq 0 ]; then
        log "ℹ️ Aucun backup local trouvé dans $BACKUP_DIR"
        return 0
    fi

    printf '%s\n' "${files[@]}"
}

# =========================================================
# RETENTION LOCALE
# =========================================================
cleanup_local_backups() {
    local old_count

    old_count=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +"$LOCAL_RETENTION_DAYS" | wc -l)

    if [ "$old_count" -gt 0 ]; then
        if [ "$DRY_RUN" = "true" ]; then
            log "🧹 [DRY-RUN] Rotation locale: $old_count fichier(s) seraient supprimé(s)"
        else
            find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +"$LOCAL_RETENTION_DAYS" -delete
            log "🧹 Rotation locale: $old_count fichier(s) supprimé(s) (rétention $LOCAL_RETENTION_DAYS jours)"
        fi
    else
        log "ℹ️ Rotation locale: aucun backup à supprimer"
    fi
}

# =========================================================
# KEEP BACKUP LOCAL
# =========================================================
delete_local_backup_if_needed() {
    local local_file="$1"

    if [ "$KEEP_LOCAL_BACKUP" = "true" ]; then
        log "   ℹ️ Politique locale: conservation du backup"
        return 0
    fi

    if [ "$REMOTE_ENABLED" != "true" ]; then
        log "   ⚠️ Suppression locale ignorée: remote désactivé"
        return 0
    fi

    if [ ! -f "$local_file" ]; then
        log "   ⚠️ Fichier local déjà absent: $local_file"
        return 0
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log "   [DRY-RUN] Suppression locale: $local_file"
        return 0
    fi

    if rm -f "$local_file"; then
        log "   🗑️ Backup local supprimé: $(basename "$local_file")"
        return 0
    fi

    log "   ❌ Échec suppression backup local: $(basename "$local_file")"
    return 1
}

# =========================================================
# RESTORE
# =========================================================
wipe_volume() {
    local volume="$1"

    log "🧹 Nettoyage du volume $volume avant restauration"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] docker run --rm -v $volume:/volume alpine sh -c 'rm -rf /volume/* /volume/.[!.]* /volume/..?*'"
        return 0
    fi

    docker run --rm \
        -v "$volume":/volume \
        alpine \
        sh -c 'rm -rf /volume/* /volume/.[!.]* /volume/..?*' >/dev/null 2>&1
}

restore_local_backup() {
    local volume="$1"
    local archive_name="$2"
    local archive_path="$BACKUP_DIR/$archive_name"

    if [ ! -f "$archive_path" ]; then
        log "❌ Archive locale introuvable: $archive_path"
        return 1
    fi

    log "♻️ Restauration locale de $archive_name vers le volume $volume"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] docker run --rm -v $volume:/volume -v $BACKUP_DIR:/backup alpine tar xzf /backup/$archive_name -C /volume"
        return 0
    fi

    docker run --rm \
        -v "$volume":/volume \
        -v "$BACKUP_DIR":/backup \
        alpine \
        sh -c "tar xzf \"/backup/$archive_name\" -C /volume" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log "✅ Restauration locale OK"
        return 0
    fi

    log "❌ Échec restauration locale"
    return 1
}

restore_sftp_backup() {
    local volume="$1"
    local archive_name="$2"
    local tmp_dir

    tmp_dir="$(mktemp -d)"

    if ! download_sftp_backup "$archive_name" "$tmp_dir"; then
        log "❌ Échec téléchargement SFTP: $archive_name"
        rm -rf "$tmp_dir"
        return 1
    fi

    log "♻️ Restauration SFTP de $archive_name vers le volume $volume"

    if [ "$DRY_RUN" = "true" ]; then
        log "[DRY-RUN] docker run --rm -v $volume:/volume -v $tmp_dir:/backup alpine tar xzf /backup/$archive_name -C /volume"
        rm -rf "$tmp_dir"
        return 0
    fi

    docker run --rm \
        -v "$volume":/volume \
        -v "$tmp_dir":/backup \
        alpine \
        sh -c "tar xzf \"/backup/$archive_name\" -C /volume" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log "✅ Restauration SFTP OK"
        rm -rf "$tmp_dir"
        return 0
    fi

    log "❌ Échec restauration SFTP"
    rm -rf "$tmp_dir"
    return 1
}

# =========================================================
# BACKUP D’UN VOLUME
# =========================================================
backup_one_volume() {
    local vol="$1"
    local backup_file
    local remote_rc

    log "🔄 Traitement du volume: $vol"

    if [ "$BACKUP_MODE" = "stop" ]; then
        if ! stop_containers_for_volume "$vol"; then
            FAILED_LOCAL_VOLUMES+=("$vol")
            return 1
        fi
    else
        log "   🔥 Mode HOT backup"
    fi

    backup_file="${vol}_${DATE}.tar.gz"

    if create_local_backup "$vol" "$backup_file"; then
        SUCCESS_LOCAL_VOLUMES+=("$vol")
        SUCCESS_COUNT_LOCAL=$((SUCCESS_COUNT_LOCAL + 1))
    else
        FAILED_LOCAL_VOLUMES+=("$vol")
        return 1
    fi

    send_remote "$BACKUP_DIR/$backup_file"
    remote_rc=$?

    case "$remote_rc" in
        0)
            SUCCESS_REMOTE_VOLUMES+=("$vol")
            SUCCESS_COUNT_REMOTE=$((SUCCESS_COUNT_REMOTE + 1))
            log "   ✅ Backup local + remote validé pour $vol"
            delete_local_backup_if_needed "$BACKUP_DIR/$backup_file"
            ;;
        10)
            log "   ℹ️ Pas de transfert remote pour $vol"
            ;;
        *)
            FAILED_REMOTE_VOLUMES+=("$vol")
            log "   ⚠️ Backup local OK mais remote KO pour $vol"
            ;;
    esac

    return 0
}

# =========================================================
# RÉSUMÉ
# =========================================================
print_summary() {
    log "================ RÉSUMÉ ================"
    log "Mode backup              : $BACKUP_MODE"
    log "Remote activé            : $REMOTE_ENABLED"
    log "Méthode remote           : $REMOTE_METHOD"
    log "Dry run                  : $DRY_RUN"
    log "Volumes valides          : ${#VOLUMES[@]}"
    log "Succès local             : $SUCCESS_COUNT_LOCAL/${#VOLUMES[@]}"
    log "Succès remote            : $SUCCESS_COUNT_REMOTE/${#VOLUMES[@]}"
    log "Espace disque backup     : $(df -h "$BACKUP_DIR" | tail -1)"

    [ ${#INVALID_VOLUMES[@]} -gt 0 ] && log "Volumes invalides        : ${INVALID_VOLUMES[*]}"
    [ ${#FAILED_LOCAL_VOLUMES[@]} -gt 0 ] && log "Échecs locaux            : ${FAILED_LOCAL_VOLUMES[*]}"
    [ ${#FAILED_REMOTE_VOLUMES[@]} -gt 0 ] && log "Échecs remote            : ${FAILED_REMOTE_VOLUMES[*]}"

    log "========================================"
}

# =========================================================
# RUNNERS
# =========================================================
run_backup() {
    local backup_failed=0

    log "🚀 Démarrage backup Docker"
    log "Configuration: mode=$BACKUP_MODE remote=$REMOTE_ENABLED method=$REMOTE_METHOD dry_run=$DRY_RUN retention-local=${LOCAL_RETENTION_DAYS}jrs retention-sftp=${SFTP_RETENTION_DAYS}jrs keep-local=$KEEP_LOCAL_BACKUP"

    resolve_volumes_for_backup || return 1

    for vol in "${VOLUMES[@]}"; do
        if ! backup_one_volume "$vol"; then
            backup_failed=1
        fi
        echo "---"
    done

    if ! cleanup_local_backups; then
        log "❌ Échec du nettoyage local"
        backup_failed=1
    fi

    if ! cleanup_remote; then
        log "❌ Échec du nettoyage remote"
        backup_failed=1
    fi

    print_summary

    if [ "$backup_failed" -ne 0 ] || [ ${#FAILED_LOCAL_VOLUMES[@]} -gt 0 ] || [ ${#FAILED_REMOTE_VOLUMES[@]} -gt 0 ]; then
        log "❌ TERMINÉ AVEC ERREURS"
        return 1
    fi

    log "✅ TERMINÉ"
    return 0
}

run_restore() {
    local volume="${VOLUMES[0]}"

    log "🚀 Démarrage restauration Docker"
    log "Configuration restore: volume=$volume archive=$RESTORE_ARCHIVE source=$RESTORE_SOURCE wipe-volume=$WIPE_VOLUME dry_run=$DRY_RUN"

    validate_restore_volume "$volume"

    if [ "$BACKUP_MODE" = "stop" ]; then
        stop_containers_for_volume "$volume" || exit 1
    else
        log "   🔥 Mode HOT restore"
    fi

    if [ "$WIPE_VOLUME" = "true" ]; then
        wipe_volume "$volume" || exit 1
    fi

    case "$RESTORE_SOURCE" in
        local)
            restore_local_backup "$volume" "$RESTORE_ARCHIVE" || exit 1
            ;;
        sftp)
            restore_sftp_backup "$volume" "$RESTORE_ARCHIVE" || exit 1
            ;;
    esac

    log "✅ RESTAURATION TERMINÉE"
}

run_list_local() {
    log "📂 Liste des backups locaux disponibles dans $BACKUP_DIR"
    list_local_backups
}

run_list_sftp() {
    log "📂 Liste des backups SFTP disponibles dans ${SFTP_REMOTE_DIR}"
    list_sftp_backups
}

# =========================================================
# MAIN
# =========================================================
main() {
    load_env
    set_defaults
    parse_action "$@"

    case "$ACTION" in
        backup)
            validate_backup_config
            ;;
        restore)
            validate_restore_config
            ;;
        list-local)
            validate_common_config
            ;;
        list-sftp)
            validate_list_sftp_config
            ;;
    esac

    acquire_lock
    trap cleanup_on_exit EXIT INT TERM

    case "$ACTION" in
        backup)
            run_backup
            exit $?
            ;;
        restore)
            run_restore
            exit $?
            ;;
        list-local)
            run_list_local
            exit $?
            ;;
        list-sftp)
            run_list_sftp
            exit $?
            ;;
    esac
}

main "$@"

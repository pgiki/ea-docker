#!/usr/bin/env bash
###############################################################################
# update.sh — Safely update an existing Easy!Appointments deployment
#
# Usage:
#   ./scripts/update.sh [--version 1.5.3] [--dir /opt/easyappointments]
#                       [--skip-backup] [--yes] [--sync-src] [--skip-preflight]
#
# Production updates use the Docker image (EA_VERSION in .env). By default this
# script does NOT replace ./src/ on disk; pass --sync-src to refresh the local
# reference copy from GitHub.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}▶ $*${NC}"; }

TARGET_VERSION=""
INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GITHUB_REPO="alextselegidis/easyappointments"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
SKIP_BACKUP=false
ASSUME_YES=false
SYNC_SRC=false
SKIP_PREFLIGHT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)   TARGET_VERSION="$2"; shift 2 ;;
    --dir|-d)       INSTALL_DIR="$2"; shift 2 ;;
    --skip-backup)  SKIP_BACKUP=true; shift ;;
    --yes|-y)       ASSUME_YES=true; shift ;;
    --sync-src)     SYNC_SRC=true; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--version <tag>] [--dir <path>] [--skip-backup] [--yes] [--sync-src] [--skip-preflight]"
      exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

ENV_FILE="${INSTALL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || error ".env not found at ${ENV_FILE}. Run install.sh first."
load_env_file "$ENV_FILE"

COMPOSE="$(compose_cmd)" || error "Docker Compose not found."
cd "${INSTALL_DIR}"

if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
  step "Preflight checks"
  bash "${SCRIPT_DIR}/preflight.sh" --dir "${INSTALL_DIR}" --update \
    || error "Preflight failed — fix the issues above or re-run with --skip-preflight"
fi

step "Resolving target version"

CURRENT_VERSION="${EA_VERSION:-unknown}"
info "Currently pinned in .env: ${CURRENT_VERSION}"

if [[ -n "$TARGET_VERSION" ]]; then
  NEW_VERSION="$TARGET_VERSION"
else
  if command -v jq &>/dev/null; then
    NEW_VERSION=$(curl -fsSL "$GITHUB_API" | jq -r '.tag_name')
  else
    NEW_VERSION=$(curl -fsSL "$GITHUB_API" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  fi
  [[ -z "$NEW_VERSION" || "$NEW_VERSION" == "null" ]] && error "Could not resolve latest version. Use --version <tag>."
fi

info "Target version: ${BOLD}${NEW_VERSION}${NC}"

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  warn "Already pinned to ${NEW_VERSION} in .env."
  if [[ "$ASSUME_YES" == "true" ]]; then
    info "--yes set; continuing."
  elif [[ -t 0 ]]; then
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Aborted."; exit 0; }
  else
    info "Non-interactive session — continuing (pass --yes to skip this message)."
  fi
fi

BACKUP_DIR=""
if [[ "$SKIP_BACKUP" == "true" ]]; then
  warn "--skip-backup specified — skipping backup (not recommended!)"
else
  step "Pre-update backup"
  BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_DIR="${INSTALL_DIR}/backups/pre-update_${BACKUP_TIMESTAMP}"
  mkdir -p "$BACKUP_DIR"

  if mysql_is_running "$COMPOSE"; then
    info "Dumping database…"
    $COMPOSE exec -T mysql \
      mysqldump \
        --user="${DB_USERNAME:-easyapp}" \
        --password="${DB_PASSWORD}" \
        --single-transaction \
        --routines \
        --triggers \
        "${DB_NAME:-easyappointments}" \
      | gzip > "${BACKUP_DIR}/db_${BACKUP_TIMESTAMP}.sql.gz"
    success "Database → ${BACKUP_DIR}/db_${BACKUP_TIMESTAMP}.sql.gz"
  else
    warn "MySQL container not running — skipping DB backup"
  fi

  info "Backing up app storage volume…"
  if $COMPOSE run --rm --no-deps \
    -v "${BACKUP_DIR}:/backup_target" \
    app \
    tar czf "/backup_target/storage_${BACKUP_TIMESTAMP}.tar.gz" -C /var/www/html storage; then
    success "Storage → ${BACKUP_DIR}/storage_${BACKUP_TIMESTAMP}.tar.gz"
  else
    warn "Storage backup failed (non-fatal)"
  fi

  success "Backup complete → ${BACKUP_DIR}"
fi

if [[ "$SYNC_SRC" == "true" ]]; then
  step "Syncing local reference source to ${NEW_VERSION}"

  ARCHIVE_URL="https://github.com/${GITHUB_REPO}/releases/download/${NEW_VERSION}/easyappointments-${NEW_VERSION}.zip"
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  ARCHIVE_PATH="${TMP_DIR}/easyappointments.zip"

  curl -fL --progress-bar -o "$ARCHIVE_PATH" "$ARCHIVE_URL" \
    || error "Download failed. Check the version tag."

  if command -v unzip &>/dev/null; then
    unzip -q -o "$ARCHIVE_PATH" -d "${TMP_DIR}/extracted"
  else
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$ARCHIVE_PATH" "${TMP_DIR}/extracted"
  fi

  EXTRACTED=$(find "${TMP_DIR}/extracted" -maxdepth 1 -mindepth 1 -type d | head -1)
  [[ -z "$EXTRACTED" ]] && error "Extraction failed — archive may be corrupt."

  mkdir -p "${INSTALL_DIR}/src"
  CONFIG_BACKUP=""
  if [[ -f "${INSTALL_DIR}/src/config.php" ]]; then
    CONFIG_BACKUP="${TMP_DIR}/config.php.bak"
    cp "${INSTALL_DIR}/src/config.php" "$CONFIG_BACKUP"
  fi

  if command -v rsync &>/dev/null; then
    rsync -a --delete \
      --exclude='storage/' \
      --exclude='config.php' \
      "${EXTRACTED}/" "${INSTALL_DIR}/src/"
  else
    find "${INSTALL_DIR}/src" -mindepth 1 -maxdepth 1 \
      ! -name 'storage' ! -name 'config.php' \
      -exec rm -rf {} +
    for item in "${EXTRACTED}"/*; do
      base=$(basename "$item")
      [[ "$base" == "storage" || "$base" == "config.php" ]] && continue
      cp -a "$item" "${INSTALL_DIR}/src/"
    done
  fi

  if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
    cp "$CONFIG_BACKUP" "${INSTALL_DIR}/src/config.php"
  fi

  [[ -d "${INSTALL_DIR}/src/storage" ]] && chmod -R 775 "${INSTALL_DIR}/src/storage"
  success "Reference source updated under ./src/"
else
  info "Skipping ./src/ sync (production uses Docker image; pass --sync-src to refresh)"
fi

sed_inplace "s|^EA_VERSION=.*|EA_VERSION=${NEW_VERSION}|" "$ENV_FILE"

step "Pulling Docker image alextselegidis/easyappointments:${NEW_VERSION}"
$COMPOSE pull app

step "Restarting stack"
$COMPOSE up -d --remove-orphans

step "Running database migrations"
info "Waiting for the app container to become healthy…"
for _ in $(seq 1 30); do
  if $COMPOSE exec -T app curl -fsSL -o /dev/null "http://localhost/index.php/backend/api/v1/availabilities" 2>/dev/null; then
    break
  fi
  sleep 2
done

MIGRATION_PATH="/index.php/backend/update"
HTTP_STATUS=$($COMPOSE exec -T app curl -o /dev/null -s -w "%{http_code}" "http://localhost${MIGRATION_PATH}" || echo "000")

if [[ "$HTTP_STATUS" == "200" ]]; then
  success "Database migrations applied (HTTP 200)"
elif [[ "$HTTP_STATUS" == "302" || "$HTTP_STATUS" == "301" ]]; then
  success "Migration endpoint redirected (${HTTP_STATUS}) — likely already up-to-date"
else
  warn "Migration endpoint returned HTTP ${HTTP_STATUS}."
  warn "Open ${BASE_URL}${MIGRATION_PATH} in your browser to run migrations manually."
fi

echo ""
success "═══════════════════════════════════════════════════════════════"
success " Update complete: ${CURRENT_VERSION} → ${NEW_VERSION}"
success " URL: ${BASE_URL}"
if [[ -n "$BACKUP_DIR" ]]; then
  success " Pre-update backup: ${BACKUP_DIR}"
fi
success "═══════════════════════════════════════════════════════════════"

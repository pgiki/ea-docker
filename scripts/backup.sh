#!/usr/bin/env bash
###############################################################################
# backup.sh — On-demand backup of the database and app storage
#
# Usage:
#   ./scripts/backup.sh [--dir /opt/easyappointments] [--output /mnt/backups]
#
# Outputs (timestamped):
#   <output>/db_YYYYMMDD_HHMMSS.sql.gz
#   <output>/storage_YYYYMMDD_HHMMSS.tar.gz
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

INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${INSTALL_DIR}/backups"
RETENTION_DAYS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|-d)       INSTALL_DIR="$2"; shift 2 ;;
    --output|-o)    OUTPUT_DIR="$2"; shift 2 ;;
    --retain|-r)    RETENTION_DAYS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dir <path>] [--output <path>] [--retain <days>]"
      exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

ENV_FILE="${INSTALL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || error ".env not found at ${ENV_FILE}"
# shellcheck disable=SC1090
source "$ENV_FILE"

RETENTION_DAYS="${RETENTION_DAYS:-${BACKUP_RETENTION_DAYS:-14}}"

COMPOSE="$(compose_cmd)" || error "Docker Compose not found."
cd "${INSTALL_DIR}"

mysql_is_running "$COMPOSE" || error "MySQL is not running. Start the stack: ${COMPOSE} up -d"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUTPUT_DIR"

step "Dumping database"

DB_FILE="${OUTPUT_DIR}/db_${TIMESTAMP}.sql.gz"

$COMPOSE exec -T mysql \
  mysqldump \
    --user="${DB_USERNAME:-easyapp}" \
    --password="${DB_PASSWORD}" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    --routines \
    --triggers \
    --events \
    "${DB_NAME:-easyappointments}" \
  | gzip -9 > "$DB_FILE"

DB_SIZE=$(du -sh "$DB_FILE" | cut -f1)
success "Database → ${DB_FILE} (${DB_SIZE})"

step "Backing up app storage"

STORAGE_FILE="${OUTPUT_DIR}/storage_${TIMESTAMP}.tar.gz"

$COMPOSE run --rm --no-deps \
  -v "${OUTPUT_DIR}:/backup_out" \
  app \
  tar czf "/backup_out/storage_${TIMESTAMP}.tar.gz" \
    -C /var/www/html \
    storage

[[ -f "$STORAGE_FILE" ]] || error "Storage backup file was not created: ${STORAGE_FILE}"

STORAGE_SIZE=$(du -sh "$STORAGE_FILE" | cut -f1)
success "Storage → ${STORAGE_FILE} (${STORAGE_SIZE})"

step "Pruning backups older than ${RETENTION_DAYS} days"

OLD_COUNT=$(find "$OUTPUT_DIR" -name "*.gz" -mtime +"$RETENTION_DAYS" | wc -l | tr -d ' ')
if [[ "$OLD_COUNT" -gt 0 ]]; then
  find "$OUTPUT_DIR" -name "*.gz" -mtime +"$RETENTION_DAYS" -delete
  success "Removed ${OLD_COUNT} old backup(s)"
else
  info "No backups older than ${RETENTION_DAYS} days"
fi

echo ""
success "═══════════════════════════════════════════════"
success " Backup complete — ${TIMESTAMP}"
success " DB:      ${DB_FILE} (${DB_SIZE})"
success " Storage: ${STORAGE_FILE} (${STORAGE_SIZE})"
success "═══════════════════════════════════════════════"

#!/usr/bin/env bash
###############################################################################
# install.sh — First-time Easy!Appointments deployment
#
# Usage:
#   ./scripts/install.sh [--version 1.5.2] [--dir /opt/easyappointments] [--skip-preflight]
#
# The running application comes from the official Docker image (see .env EA_VERSION).
# An optional source tree under ./src/ is downloaded for reference only; it is not
# mounted into the app container.
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

EA_VERSION=""
INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKIP_PREFLIGHT=false
GITHUB_REPO="alextselegidis/easyappointments"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v) EA_VERSION="$2"; shift 2 ;;
    --dir|-d)     INSTALL_DIR="$2"; shift 2 ;;
    --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--version <tag>] [--dir <path>]"
      exit 0 ;;
    *) error "Unknown option: $1" ;;
  esac
done

step "Checking dependencies"

check_cmd() {
  command -v "$1" &>/dev/null || error "'$1' is not installed. Please install it and retry."
}

check_cmd docker
check_cmd curl
check_cmd openssl

COMPOSE="$(compose_cmd)" || error "Docker Compose not found. Install the Docker Compose plugin."

success "All dependencies satisfied"

mkdir -p "${INSTALL_DIR}/backups" "${INSTALL_DIR}/mysql/init"

step "Resolving Easy!Appointments version"

if [[ -z "$EA_VERSION" ]]; then
  info "No version specified — fetching latest release from GitHub…"
  if command -v jq &>/dev/null; then
    EA_VERSION=$(curl -fsSL "$GITHUB_API" | jq -r '.tag_name')
  else
    EA_VERSION=$(curl -fsSL "$GITHUB_API" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  fi
  [[ -z "$EA_VERSION" || "$EA_VERSION" == "null" ]] && error "Could not determine latest release. Pass --version manually."
fi

info "Target version: ${BOLD}${EA_VERSION}${NC}"

step "Downloading release archive (reference copy → ${INSTALL_DIR}/src)"

ARCHIVE_URL="https://github.com/${GITHUB_REPO}/releases/download/${EA_VERSION}/easyappointments-${EA_VERSION}.zip"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE_PATH="${TMP_DIR}/easyappointments.zip"

info "Source: ${ARCHIVE_URL}"
curl -fL --progress-bar -o "$ARCHIVE_PATH" "$ARCHIVE_URL" \
  || error "Download failed. Check the version tag or your internet connection."

mkdir -p "${INSTALL_DIR}/src"

if command -v unzip &>/dev/null; then
  unzip -q -o "$ARCHIVE_PATH" -d "${TMP_DIR}/extracted"
else
  check_cmd python3
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
    "$ARCHIVE_PATH" "${TMP_DIR}/extracted"
fi

EXTRACTED=$(find "${TMP_DIR}/extracted" -maxdepth 1 -mindepth 1 -type d | head -1)
[[ -z "$EXTRACTED" ]] && error "Nothing extracted — archive may be malformed."

cp -r "${EXTRACTED}/." "${INSTALL_DIR}/src/"
success "Source reference at ${INSTALL_DIR}/src"

step "Setting permissions on storage/"

STORAGE_DIR="${INSTALL_DIR}/src/storage"
if [[ -d "$STORAGE_DIR" ]]; then
  chmod -R 775 "$STORAGE_DIR"
  success "storage/ is writable"
else
  warn "storage/ not in archive — live data lives in the app_storage Docker volume"
fi

step "Configuring environment"

ENV_FILE="${INSTALL_DIR}/.env"
ENV_EXAMPLE="${INSTALL_DIR}/.env.example"

ENV_JUST_CREATED=false
if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists — skipping generation (delete it to regenerate)"
else
  ENV_JUST_CREATED=true
  [[ -f "$ENV_EXAMPLE" ]] || error ".env.example not found at ${ENV_EXAMPLE}"
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  DB_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 32)
  DB_ROOT_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#%^&*' | head -c 32)
  sed_inplace "s|CHANGE_ME_strong_app_password|$(escape_sed_replacement "$DB_PASS")|g" "$ENV_FILE"
  sed_inplace "s|CHANGE_ME_strong_root_password|$(escape_sed_replacement "$DB_ROOT_PASS")|g" "$ENV_FILE"
  success ".env created with auto-generated passwords"
  echo ""
  warn "───────────────────────────────────────────────────────────────"
  warn " ACTION REQUIRED: edit .env and set:"
  warn "   BASE_URL, DOMAIN, ACME_EMAIL, MAIL_*, etc."
  warn " Generated DB_PASSWORD:        ${DB_PASS}"
  warn " Generated DB_ROOT_PASSWORD:   ${DB_ROOT_PASS}"
  warn "───────────────────────────────────────────────────────────────"
  echo ""
fi

sed_inplace "s|^EA_VERSION=.*|EA_VERSION=${EA_VERSION}|" "$ENV_FILE"

if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
  step "Preflight checks"
  PREFLIGHT_ARGS=(--dir "${INSTALL_DIR}" --install)
  [[ "$ENV_JUST_CREATED" == "true" ]] && PREFLIGHT_ARGS+=(--allow-placeholders)
  bash "${SCRIPT_DIR}/preflight.sh" "${PREFLIGHT_ARGS[@]}" \
    || error "Preflight failed — fix the issues above or re-run with --skip-preflight"
fi

step "Pulling Docker images"
cd "${INSTALL_DIR}"
$COMPOSE pull

step "Starting stack"
$COMPOSE up -d

echo ""
success "═══════════════════════════════════════════════════════════════"
success " Easy!Appointments ${EA_VERSION} is starting up!"
success ""
# shellcheck disable=SC1090
source "$ENV_FILE" 2>/dev/null || true
success " URL: ${BASE_URL:-http://localhost}"
success ""
success " First run: visit the URL to complete the web installer."
success " Backend:   \${BASE_URL}/index.php/backend"
success " Logs:      ${COMPOSE} logs -f"
success "═══════════════════════════════════════════════════════════════"

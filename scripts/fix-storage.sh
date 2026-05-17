#!/usr/bin/env bash
###############################################################################
# fix-storage.sh — Seed an empty app_storage volume from the Docker image
#
# Run this if the app returns HTTP 500 and logs show errors about storage/
# (empty volume replaced the image's storage directory).
#
# Usage: ./scripts/fix-storage.sh [--dir /opt/ea-docker]
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|-d) INSTALL_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--dir <path>]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ENV_FILE="${INSTALL_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo ".env not found" >&2; exit 1; }
load_env_file "$ENV_FILE"

COMPOSE="$(compose_cmd)" || { echo "Docker Compose not found" >&2; exit 1; }
cd "${INSTALL_DIR}"

VERSION="${EA_VERSION:-latest}"
echo "Seeding app_storage from alextselegidis/easyappointments:${VERSION}..."

$COMPOSE run --rm --no-deps --user root storage-init

echo "Done. Restart the app: ${COMPOSE} up -d --force-recreate app caddy"

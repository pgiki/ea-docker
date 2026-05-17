#!/usr/bin/env bash
###############################################################################
# fix-storage.sh — Seed an empty app_storage volume from the Docker image
#
# Run this if the app returns HTTP 500 and logs show errors about storage/
# (empty volume replaced the image's storage directory).
#
# Usage: ./scripts/fix-storage.sh [--dir /opt/ea-docker] [--force]
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|-d) INSTALL_DIR="$2"; shift 2 ;;
    --force|-f) FORCE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dir <path>] [--force]"
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
IMAGE="alextselegidis/easyappointments:${VERSION}"

seed_storage() {
  local wipe="$1"
  local wipe_cmd=""
  [[ "$wipe" == "true" ]] && wipe_cmd="rm -rf /mnt/storage/* /mnt/storage/.[!.]* 2>/dev/null || true;"
  local vol
  vol=$($COMPOSE volume ls -q | grep app_storage | head -1)
  [[ -n "$vol" ]] || { echo "app_storage volume not found" >&2; return 1; }
  docker run --rm --user root \
    -v "${vol}:/mnt/storage" \
    "$IMAGE" \
    bash -c "${wipe_cmd} cp -a /var/www/html/storage/. /mnt/storage/; chown -R www-data:www-data /mnt/storage; touch /mnt/storage/.docker-seeded"
}

if [[ "$FORCE" == "true" ]]; then
  echo "Force re-seeding app_storage (replaces storage volume contents)..."
  seed_storage true
else
  echo "Seeding app_storage if needed..."
  $COMPOSE run --rm --no-deps --user root storage-init
fi

echo "Done. Restart the app: ${COMPOSE} up -d --force-recreate app"

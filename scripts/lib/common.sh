# shellcheck shell=bash
# Shared helpers for install/update/backup scripts.

# Detect docker compose v2 or v1.
compose_cmd() {
  if docker compose version &>/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    return 1
  fi
}

# GNU sed (Linux) vs BSD sed (macOS).
sed_inplace() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Escape a string for use as the replacement in sed (delimiter: |).
escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

# Return 0 when the mysql service container is running.
mysql_is_running() {
  local compose="$1"
  $compose ps mysql 2>/dev/null | grep -qiE 'running|up'
}

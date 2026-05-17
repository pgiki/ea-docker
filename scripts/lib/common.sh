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

# Load .env without executing it (safe for values like cron: 0 2 * * *).
load_env_file() {
  local file="$1"
  local line key val
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then
      val="${BASH_REMATCH[1]}"
    elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    printf -v "$key" '%s' "$val"
    export "$key"
  done < "$file"
}

# Run a command as root when not already root.
run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo &>/dev/null; then
    sudo "$@"
  else
    return 1
  fi
}

# True when using the stack's bundled Caddy (not host Caddy on 80/443).
using_builtin_caddy() {
  [[ "${COMPOSE_PROFILES:-}" == *builtin-caddy* ]]
}

# Install /etc/caddy/sites/<domain>.caddy for external Caddy mode.
# Args: domain upstream_host upstream_port [sites_dir]
install_host_caddy_site() {
  local domain="$1"
  local upstream_host="${2:-127.0.0.1}"
  local upstream_port="${3:-8086}"
  local sites_dir="${4:-${CADDY_SITES_DIR:-/etc/caddy/sites}}"

  if [[ -z "$domain" ]]; then
    echo "DOMAIN is not set" >&2
    return 1
  fi
  if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "DOMAIN contains invalid characters: ${domain}" >&2
    return 1
  fi

  local site_file="${sites_dir}/${domain}.caddy"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
${domain} {
	reverse_proxy ${upstream_host}:${upstream_port} {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
	}
}
EOF

  if ! run_root mkdir -p "$sites_dir"; then
    echo "Could not create ${sites_dir} (try sudo)" >&2
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$site_file" ]] && run_root test -f "$site_file"; then
    if run_root cmp -s "$tmp" "$site_file" 2>/dev/null; then
      rm -f "$tmp"
      echo "$site_file"
      return 0
    fi
    run_root cp -a "$site_file" "${site_file}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi

  if ! run_root cp "$tmp" "$site_file"; then
    echo "Could not write ${site_file} (try sudo)" >&2
    rm -f "$tmp"
    return 1
  fi
  run_root chmod 644 "$site_file" 2>/dev/null || true
  rm -f "$tmp"
  echo "$site_file"
  return 0
}

# Reload host Caddy after site file changes.
reload_host_caddy() {
  if run_root systemctl is-active --quiet caddy 2>/dev/null; then
    run_root systemctl reload caddy && return 0
  fi
  if command -v caddy &>/dev/null; then
    local main_cfg="/etc/caddy/Caddyfile"
    [[ -f "$main_cfg" ]] || return 1
    run_root caddy validate --config "$main_cfg" &>/dev/null \
      && run_root caddy reload --config "$main_cfg" &>/dev/null && return 0
  fi
  return 1
}

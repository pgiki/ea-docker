#!/usr/bin/env bash
###############################################################################
# preflight.sh — Validate environment before install or update
#
# Usage:
#   ./scripts/preflight.sh [--dir /opt/easyappointments]
#   ./scripts/preflight.sh --install    # also require HTTP/HTTPS ports free
#   ./scripts/preflight.sh --update     # allow ports in use (stack running)
#   ./scripts/preflight.sh --strict     # treat warnings as errors
#   ./scripts/preflight.sh --allow-placeholders  # warn instead of fail (fresh .env)
#
# Exit 0 = ready, 1 = fix reported errors (warnings alone exit 0 unless --strict)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; ERR_COUNT=$((ERR_COUNT + 1)); }
step()    { echo -e "\n${BOLD}▶ $*${NC}"; }

INSTALL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE="general"   # general | install | update
STRICT=false
ALLOW_PLACEHOLDERS=false
ERR_COUNT=0
WARN_COUNT=0

LOCAL_HOSTNAMES='^(localhost|127\.0\.0\.1|::1)$'

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir|-d)     INSTALL_DIR="$2"; shift 2 ;;
    --install)    MODE="install"; shift ;;
    --update)     MODE="update"; shift ;;
    --strict)     STRICT=true; shift ;;
    --allow-placeholders) ALLOW_PLACEHOLDERS=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dir <path>] [--install | --update] [--strict] [--allow-placeholders]"
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
CADDY_FILE="${INSTALL_DIR}/caddy/Caddyfile"

is_local_domain() {
  [[ "$1" =~ $LOCAL_HOSTNAMES ]]
}

is_placeholder() {
  local val="$1"
  [[ -z "$val" ]] && return 0
  [[ "$val" == *CHANGE_ME* ]] && return 0
  [[ "$val" == *example.com* ]] && return 0
  [[ "$val" == *example.org* ]] && return 0
  [[ "$val" == your-smtp-* ]] && return 0
  return 1
}

# Extract hostname from URL (https://host/path → host).
url_host() {
  local url="$1"
  if [[ "$url" =~ ^https?://([^/:]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Return 0 if something is listening on TCP port on this host.
port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -ltn 2>/dev/null | grep -qE ":${port}([[:space:]]|$)"
  elif command -v lsof &>/dev/null; then
    lsof -iTCP:"${port}" -sTCP:LISTEN -P -n &>/dev/null
  elif command -v nc &>/dev/null; then
    nc -z 127.0.0.1 "$port" 2>/dev/null
  else
    (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
  fi
}

# Resolve DOMAIN to one or more IPs (space-separated).
resolve_domain() {
  local domain="$1"
  local ips=""
  if command -v getent &>/dev/null; then
    ips=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  fi
  if [[ -z "${ips// }" ]] && command -v dig &>/dev/null; then
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ')
  fi
  if [[ -z "${ips// }" ]] && command -v python3 &>/dev/null; then
    ips=$(python3 -c "import socket; print(' '.join(sorted({ai[4][0] for ai in socket.getaddrinfo('$domain', None, proto=socket.IPPROTO_TCP)})))" 2>/dev/null || true)
  fi
  echo "${ips%% }"
}

# Best-effort public IPv4 of this machine.
detect_public_ip() {
  local ip=""
  if command -v curl &>/dev/null; then
    ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  fi
  if [[ -z "$ip" ]] && command -v curl &>/dev/null; then
    ip=$(curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)
  fi
  echo "$ip"
}

# Collect non-loopback IPv4 addresses on this host.
local_ipv4_addresses() {
  if command -v ip &>/dev/null; then
    ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
  elif command -v ifconfig &>/dev/null; then
    ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2}' | sed 's/addr://'
  fi
}

finish() {
  echo ""
  echo -e "${BOLD}── Summary ──${NC}"
  if [[ "$ERR_COUNT" -gt 0 ]]; then
    echo -e "${RED}${ERR_COUNT} error(s)${NC}, ${YELLOW}${WARN_COUNT} warning(s)${NC}"
    exit 1
  fi
  if [[ "$WARN_COUNT" -gt 0 && "$STRICT" == "true" ]]; then
    echo -e "${YELLOW}${WARN_COUNT} warning(s)${NC} (strict mode — failing)"
    exit 1
  fi
  if [[ "$WARN_COUNT" -gt 0 ]]; then
    echo -e "${GREEN}Ready with ${WARN_COUNT} warning(s)${NC} — review above before production cutover"
  else
    success "All preflight checks passed"
  fi
  exit 0
}

echo -e "${BOLD}Easy!Appointments preflight${NC} (${MODE})"
echo "Directory: ${INSTALL_DIR}"

# ─── Files & tooling ─────────────────────────────────────────────────────────
step "Tooling and layout"

command -v docker &>/dev/null || fail "docker is not installed"
success "docker found"

if COMPOSE_BIN=$(compose_cmd 2>/dev/null); then
  success "Docker Compose found (${COMPOSE_BIN})"
else
  fail "Docker Compose not found"
fi

[[ -f "$COMPOSE_FILE" ]] || fail "Missing ${COMPOSE_FILE}"
success "docker-compose.yml present"

[[ -f "$CADDY_FILE" ]] || fail "Missing ${CADDY_FILE}"
success "caddy/Caddyfile present"

[[ -d "${INSTALL_DIR}/mysql/conf.d" ]] || warn "mysql/conf.d/ missing (MySQL may use defaults only)"

if [[ -f "$ENV_FILE" ]]; then
  perm=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%OLp' "$ENV_FILE" 2>/dev/null || echo "")
  if [[ -n "$perm" ]] && [[ "$perm" != "600" && "$perm" != "400" ]]; then
    warn ".env permissions are ${perm} (recommended: chmod 600 .env)"
  else
    success ".env permissions look restricted"
  fi
else
  fail ".env not found — run: cp .env.example .env && edit values"
fi

load_env_file "$ENV_FILE"

COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
COMPOSE_FILE_VAR="${COMPOSE_FILE:-}"
BUILTIN_CADDY=false
[[ "$COMPOSE_PROFILES" == *builtin-caddy* ]] && BUILTIN_CADDY=true

if [[ -n "$COMPOSE_FILE_VAR" ]] && [[ "$COMPOSE_FILE_VAR" == *builtin-caddy* ]] && [[ "$BUILTIN_CADDY" == "false" ]]; then
  fail "COMPOSE_FILE includes docker-compose.builtin-caddy.yml but COMPOSE_PROFILES is not builtin-caddy — app port ${APP_UPSTREAM_PORT:-8086} will not be published. Remove COMPOSE_FILE from .env for external Caddy mode."
fi

HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
APP_UPSTREAM_BIND="${APP_UPSTREAM_BIND:-127.0.0.1}"
APP_UPSTREAM_PORT="${APP_UPSTREAM_PORT:-8086}"

# ─── Required variables ────────────────────────────────────────────────────────
step "Environment variables"

check_required() {
  local name="$1" val="${!1:-}"
  if [[ -z "$val" ]]; then
    fail "${name} is not set in .env"
  elif is_placeholder "$val"; then
    if [[ "$ALLOW_PLACEHOLDERS" == "true" ]]; then
      warn "${name} still has a placeholder — edit .env before going live (${val})"
    else
      fail "${name} still has a placeholder value (${val})"
    fi
  else
    success "${name}"
  fi
}

check_required BASE_URL
check_required DB_PASSWORD
check_required DB_ROOT_PASSWORD
check_required DOMAIN
if [[ "$BUILTIN_CADDY" == "true" ]]; then
  check_required ACME_EMAIL
else
  info "External Caddy mode (COMPOSE_PROFILES does not include builtin-caddy)"
  success "ACME_EMAIL not required in this stack — TLS is on your main Caddy"
fi
check_required MAIL_SMTP_HOST
check_required MAIL_FROM_ADDRESS

if [[ "${DEBUG_MODE:-FALSE}" == "TRUE" ]]; then
  warn "DEBUG_MODE=TRUE — set FALSE in production"
else
  success "DEBUG_MODE is not enabled"
fi

if [[ "${EA_VERSION:-latest}" == "latest" ]]; then
  warn "EA_VERSION=latest — pin a release tag in production"
fi

BASE_HOST=$(url_host "$BASE_URL")
if [[ -z "$BASE_HOST" ]]; then
  fail "BASE_URL is not a valid http(s) URL: ${BASE_URL}"
elif [[ "$BASE_URL" == */ ]]; then
  warn "BASE_URL has a trailing slash — remove it (${BASE_URL})"
else
  success "BASE_URL format"
fi

if is_local_domain "$DOMAIN"; then
  info "DOMAIN=${DOMAIN} — skipping public DNS/TLS checks (local deployment)"
  LOCAL_DEPLOY=true
else
  LOCAL_DEPLOY=false
  if [[ "$BASE_HOST" != "$DOMAIN" ]]; then
    fail "BASE_URL host (${BASE_HOST}) does not match DOMAIN (${DOMAIN})"
  else
    success "BASE_URL host matches DOMAIN"
  fi

  if [[ "$BASE_URL" != https://* ]]; then
    warn "BASE_URL should use https:// for production (${BASE_URL})"
  else
    success "BASE_URL uses HTTPS"
  fi

  if [[ "$ACME_EMAIL" != *@* ]]; then
    fail "ACME_EMAIL does not look like an email address"
  fi
fi

# ─── DNS ─────────────────────────────────────────────────────────────────────
if [[ "$LOCAL_DEPLOY" == "false" ]]; then
  step "DNS (${DOMAIN})"

  RESOLVED=$(resolve_domain "$DOMAIN")
  if [[ -z "${RESOLVED// }" ]]; then
    fail "Could not resolve ${DOMAIN} — check DNS A/AAAA records"
  else
    success "Resolves to: ${RESOLVED}"
  fi

  PUBLIC_IP=$(detect_public_ip)
  if [[ -n "$PUBLIC_IP" ]]; then
    if echo " $RESOLVED " | grep -q " ${PUBLIC_IP} "; then
      success "DNS includes this server's public IP (${PUBLIC_IP})"
    else
      warn "DNS (${RESOLVED}) does not include detected public IP (${PUBLIC_IP}) — OK if behind a load balancer or not using ipify"
    fi
  else
    warn "Could not detect public IP (offline?) — verify DNS points to this server manually"
  fi

  # Also check if any resolved IP is a local interface (bare-metal / VPS)
  MATCHED_LOCAL=false
  while read -r lip; do
    [[ -z "$lip" ]] && continue
    if echo " $RESOLVED " | grep -q " ${lip} "; then
      MATCHED_LOCAL=true
      success "DNS includes a local interface address (${lip})"
    fi
  done < <(local_ipv4_addresses)

  if [[ "$MATCHED_LOCAL" == "false" && -z "$PUBLIC_IP" ]]; then
    info "Could not confirm DNS targets this host — verify manually"
  fi
fi

# ─── Ports ───────────────────────────────────────────────────────────────────
if [[ "$BUILTIN_CADDY" == "true" ]]; then
  step "Ports (builtin Caddy — HTTP ${HTTP_PORT}, HTTPS ${HTTPS_PORT})"
else
  step "Ports (external Caddy — app upstream ${APP_UPSTREAM_BIND}:${APP_UPSTREAM_PORT})"
fi

check_port() {
  local port="$1" label="$2"
  if port_in_use "$port"; then
    if [[ "$MODE" == "install" ]]; then
      fail "Port ${port} (${label}) is already in use"
    else
      warn "Port ${port} (${label}) is in use (expected if the stack is already running)"
    fi
  else
    if [[ "$MODE" == "update" ]]; then
      warn "Port ${port} (${label}) is not in use — is the stack stopped?"
    else
      success "Port ${port} (${label}) is available"
    fi
  fi
}

if [[ "$BUILTIN_CADDY" == "true" ]]; then
  check_port "$HTTP_PORT" "HTTP"
  check_port "$HTTPS_PORT" "HTTPS"
  if [[ "$LOCAL_DEPLOY" == "false" ]]; then
    if [[ "$HTTP_PORT" != "80" || "$HTTPS_PORT" != "443" ]]; then
      warn "HTTP_PORT=${HTTP_PORT} HTTPS_PORT=${HTTPS_PORT} — Let's Encrypt requires public 80/443 unless you DNAT"
    else
      success "HTTP_PORT/HTTPS_PORT are 80/443"
    fi
  fi
else
  check_port "$APP_UPSTREAM_PORT" "app upstream"
  if port_in_use 80 || port_in_use 443; then
    success "Host ports 80/443 in use — expected when your main Caddy handles TLS"
  else
    warn "Ports 80/443 are free — ensure your main Caddy is running and proxies to ${APP_UPSTREAM_BIND}:${APP_UPSTREAM_PORT}"
  fi
  info "Add caddy/external-proxy.Caddyfile.example to your main Caddy, then: caddy reload"
fi

# ─── Running stack (update mode) ─────────────────────────────────────────────
if [[ "$MODE" == "update" ]]; then
  step "Running services"
  COMPOSE="$(compose_cmd)"
  cd "${INSTALL_DIR}"
  if mysql_is_running "$COMPOSE"; then
    success "MySQL container is running"
  else
    warn "MySQL is not running — update will start it, but backup needs a running DB"
  fi
  if $COMPOSE ps app 2>/dev/null | grep -qiE 'running|up'; then
    success "App container is running"
  else
    warn "App container is not running"
  fi
fi

finish

# Easy!Appointments — Production Docker Deployment

Self-hosted appointment scheduler · [GitHub](https://github.com/alextselegidis/easyappointments)

---

## Stack

| Service | Image | Purpose |
|---|---|---|
| **app** | `alextselegidis/easyappointments` | PHP application (Apache built-in) |
| **mysql** | `mysql:8.0` | Relational database |
| **caddy** | `caddy:2-alpine` | Optional — only with `COMPOSE_PROFILES=builtin-caddy` |
| **backup** | `fradelg/mysql-cron-backup` | Scheduled database backups |

Application code runs from the **Docker image** (`EA_VERSION` in `.env`). The optional `./src/` directory is a local reference copy only.

---

## Reverse proxy: existing Caddy on 80/443 (recommended)

If **another Caddy already uses ports 80 and 443**, do not run a second one in this stack. Use **external proxy mode** (the default):

1. In `.env` leave `COMPOSE_PROFILES` empty (or comment it out).
2. Set `APP_UPSTREAM_PORT=8086` (or any free local port).
3. Start Easy!Appointments only:

```bash
docker compose up -d
# Stops the old bundled caddy container if it exists:
docker rm -f easyappointments_caddy 2>/dev/null || true
```

4. **install.sh** creates `/etc/caddy/sites/<DOMAIN>.caddy` automatically (needs sudo). Or add manually (see `caddy/external-proxy.Caddyfile.example`):

```caddy
book.fikashop.app {
    reverse_proxy 127.0.0.1:8086
}
```

Your main `/etc/caddy/Caddyfile` must import that directory, for example:

```caddy
import /etc/caddy/sites/*
```

5. Reload your main Caddy (install.sh tries this for you):

```bash
caddy reload --config /etc/caddy/Caddyfile
# or however you manage your existing instance
```

6. Ensure `BASE_URL=https://book.fikashop.app` matches that hostname (no `:8086` in the URL).

Your main Caddy keeps Let's Encrypt on 80/443. This stack only serves HTTP on `127.0.0.1:8086`.

### Main Caddy in Docker?

- **Same host, Caddy on host network / host ports:** use `reverse_proxy 127.0.0.1:8086` or `172.17.0.1:8086`.
- **Caddy in another compose project:** use `docker-compose.docker-proxy.yml` and `reverse_proxy easyappointments_app:80` on a shared network (documented in the example file).

### Builtin Caddy (only if 80/443 are free)

Do **not** set `COMPOSE_FILE` in `.env` for external mode — it can silently remove port 8086.

```bash
COMPOSE_PROFILES=builtin-caddy docker compose \
  -f docker-compose.yml -f docker-compose.builtin-caddy.yml up -d
```

---

## Directory layout

```
easyappointments/
├── docker-compose.yml
├── .env.example          ← copy to .env and edit
├── Makefile              ← convenience shortcuts
├── caddy/
│   ├── Caddyfile                          ← bundled Caddy (builtin-caddy profile only)
│   └── external-proxy.Caddyfile.example   ← snippet for your main Caddy
├── mysql/
│   ├── conf.d/production.cnf
│   └── init/             ← optional seed SQL
├── scripts/
│   ├── install.sh        ← first-time setup
│   ├── update.sh         ← upgrade image + run migrations
│   ├── backup.sh         ← on-demand backup
│   ├── preflight.sh      ← validate .env, DNS, ports
│   └── lib/common.sh     ← shared helpers
└── backups/              ← backup output (gitignored)
```

---

## Quick start

### 1 — Place these files on your server

```bash
git clone https://github.com/yourorg/ea-docker.git
cd ea-docker
```

### 2 — Configure environment

```bash
cp .env.example .env
nano .env
```

Minimum required settings:

| Variable | Example |
|---|---|
| `BASE_URL` | `https://appointments.example.com` |
| `DOMAIN` | `appointments.example.com` |
| `ACME_EMAIL` | `admin@example.com` |
| `DB_PASSWORD` | *(strong random string)* |
| `DB_ROOT_PASSWORD` | *(different strong random string)* |
| `MAIL_SMTP_HOST` | `smtp.sendgrid.net` |
| `MAIL_FROM_ADDRESS` | `noreply@example.com` |

### 3 — Preflight (recommended)

```bash
chmod +x scripts/*.sh
cp .env.example .env && nano .env   # if not done yet
./scripts/preflight.sh --install    # or: make preflight (after .env exists)
```

Checks Docker, required `.env` values, `BASE_URL` vs `DOMAIN`, DNS (public hosts), and that ports 80/443 are free.

### 4 — Install and start

```bash
./scripts/install.sh        # runs preflight automatically; or: make install
```

This will fetch a reference source tarball, generate passwords if needed, pull images, and start the stack.

### 5 — Complete the web installer

Open your `BASE_URL` and follow the setup wizard.

### 6 — HTTPS

- **External Caddy:** TLS is handled by your existing Caddy — add the site block from step 5 in [Reverse proxy](#reverse-proxy-existing-caddy-on-80443-recommended).
- **Builtin Caddy:** With `COMPOSE_PROFILES=builtin-caddy` and free ports 80/443, this stack obtains Let's Encrypt certificates automatically.

Ensure `BASE_URL` uses `https://` and matches `DOMAIN`.

---

## Preflight

```bash
./scripts/preflight.sh              # general checks
./scripts/preflight.sh --install    # before first deploy (ports must be free)
./scripts/preflight.sh --update     # before upgrade (ports may be in use)
./scripts/preflight.sh --strict     # fail on warnings (CI / production gate)

make preflight
make preflight-strict
```

`install.sh` and `update.sh` run preflight automatically unless you pass `--skip-preflight`.

---

## Updating

```bash
# Latest release (backs up DB + storage first)
./scripts/update.sh

# Specific version
./scripts/update.sh --version 1.5.3

# Non-interactive (cron/CI)
./scripts/update.sh --yes

# Also refresh ./src/ reference copy
./scripts/update.sh --sync-src

make update
make update-to VERSION=1.5.3
```

The update script:

1. Backs up the database and `app_storage` volume
2. Updates `EA_VERSION` in `.env` and pulls the new image
3. Restarts the stack
4. Runs DB migrations inside the app container (no public URL required)

---

## Backup & restore

### On-demand backup

```bash
./scripts/backup.sh
./scripts/backup.sh --output /mnt/nas
make backup
```

The `backup` service in `docker-compose.yml` also runs on `BACKUP_CRON` (default 2 AM daily).

### Restore database

```bash
gunzip -c backups/db_20240101_020000.sql.gz | \
  docker compose exec -T mysql mysql \
    -u"${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_NAME}"
```

### Restore storage

```bash
docker compose run --rm --no-deps \
  -v "$(pwd)/backups:/src:ro" app \
  tar xzf /src/storage_20240101_020000.tar.gz -C /var/www/html
```

---

## Common operations

| Task | Command |
|---|---|
| Start all services | `docker compose up -d` or `make start` |
| Stop all services | `make stop` |
| View logs | `make logs` |
| Caddy logs | `make logs-caddy` |
| App shell | `make shell-app` |
| MySQL shell | `make shell-db` |
| Status | `make status` |
| Validate before deploy | `make preflight` |

---

## Environment variable reference

See `.env.example` for full comments.

| Variable | Required | Description |
|---|---|---|
| `BASE_URL` | ✅ | Full public URL (no trailing slash) |
| `DOMAIN` | ✅ | Hostname Caddy serves (Let's Encrypt) |
| `ACME_EMAIL` | ✅ | Let's Encrypt contact email |
| `EA_VERSION` | — | Image tag (pin in production, e.g. `1.5.2`) |
| `DB_PASSWORD` | ✅ | MySQL app user password |
| `DB_ROOT_PASSWORD` | ✅ | MySQL root password |
| `MAIL_SMTP_*` | ✅ | SMTP settings |
| `BACKUP_CRON` | — | Cron for automated DB backups |
| `BACKUP_RETENTION_DAYS` | — | Backup files to keep (default `14`) |

---

## Security checklist

- [ ] `chmod 600 .env`
- [ ] `DEBUG_MODE=FALSE`
- [ ] Strong unique DB passwords
- [ ] `DOMAIN` / `BASE_URL` match; DNS and ports 80/443 open for TLS
- [ ] Firewall: only 80/443 public; MySQL not exposed
- [ ] Backups copied off-server
- [ ] `EA_VERSION` pinned to a release tag (not `latest`)

---

## Troubleshooting

**App won't start / `dependency app failed to start` / unhealthy**

```bash
docker compose logs app --tail=50
docker compose ps
docker compose up -d --force-recreate storage-init app caddy
```

**`curl: connection refused` on port 8086**

The app is not published on the host. Check:

```bash
grep COMPOSE_FILE .env    # must be empty for external Caddy mode
docker compose ps
docker port easyappointments_app
```

If `COMPOSE_FILE` includes `docker-compose.builtin-caddy.yml`, remove that line and run `docker compose up -d --force-recreate app`.

**HTTP 500 on `/` or `/index.php`**

Usually an **empty or partial `app_storage` volume**. Re-seed and restart:

```bash
make fix-storage
./scripts/fix-storage.sh --force
docker compose up -d --force-recreate app
```

Then open your `BASE_URL` and complete the web installer. For details: `docker compose exec app cat /var/www/html/storage/logs/log-$(date +%Y-%m-%d).php` (with `DEBUG_MODE=TRUE` in `.env`).

**Backup: `PROCESS privilege` / tablespaces**

Ensure `MYSQLDUMP_OPTS=--no-tablespaces` is set on the `backup` service (included in current `docker-compose.yml`).

**Caddy / TLS / Let's Encrypt fails (`tls: internal error`)**

Let's Encrypt always connects to your server on **ports 80 and 443** (not custom ports like 8086/8087).

1. In `.env` set `HTTP_PORT=80` and `HTTPS_PORT=443` (defaults in `.env.example`).
2. Stop any other web server using 80/443 on the host:

```bash
sudo ss -tlnp | grep -E ':80 |:443 '
```

3. Open the firewall for 80/tcp and 443/tcp.
4. Recreate Caddy:

```bash
docker compose up -d --force-recreate caddy
docker compose logs caddy --tail=30
```

If you must keep Caddy on 8086/8087, forward traffic on the host, for example:

```bash
sudo iptables -t nat -A PREROUTING -p tcp --dport 80  -j REDIRECT --to-port 8086
sudo iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8087
```

Or terminate TLS on an upstream proxy and set `DOMAIN=localhost` / HTTP-only Caddy (no automatic certificates).

```bash
docker compose logs caddy --tail=50
```

Check `DOMAIN`, `ACME_EMAIL`, and DNS.

**502 from Caddy**

The app may still be starting (migrations on first boot). Wait ~60s: `docker compose ps`

**Migrations after update**

```bash
docker compose exec app curl -v http://localhost/index.php/backend/update
```

Or open `BASE_URL/index.php/backend/update` in a browser.

**Reset everything (destroys data)**

```bash
docker compose down -v
make install
```

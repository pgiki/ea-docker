# Easy!Appointments — Production Docker Deployment

Self-hosted appointment scheduler · [GitHub](https://github.com/alextselegidis/easyappointments)

---

## Stack

| Service | Image | Purpose |
|---|---|---|
| **app** | `alextselegidis/easyappointments` | PHP application (Apache built-in) |
| **mysql** | `mysql:8.0` | Relational database |
| **caddy** | `caddy:2-alpine` | Reverse proxy, automatic TLS (Let's Encrypt) |
| **backup** | `fradelg/mysql-cron-backup` | Scheduled database backups |

Application code runs from the **Docker image** (`EA_VERSION` in `.env`). The optional `./src/` directory is a local reference copy only.

---

## Directory layout

```
easyappointments/
├── docker-compose.yml
├── .env.example          ← copy to .env and edit
├── Makefile              ← convenience shortcuts
├── caddy/
│   └── Caddyfile         ← reverse proxy + TLS
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

With a real `DOMAIN`, DNS pointing at this server, and ports **80/443** open, Caddy obtains a Let's Encrypt certificate automatically on first start. Ensure `BASE_URL` uses `https://` and matches `DOMAIN`.

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

**HTTP 500 on `/` or `/index.php`**

Usually an **empty `app_storage` volume** — it replaces the image's `storage/` folder (logs, cache, sessions). Seed it:

```bash
make fix-storage
# or: ./scripts/fix-storage.sh
docker compose up -d --force-recreate app caddy
```

Then open your `BASE_URL` and complete the web installer. For details: `docker compose exec app cat /var/www/html/storage/logs/log-$(date +%Y-%m-%d).php` (with `DEBUG_MODE=TRUE` in `.env`).

**Backup: `PROCESS privilege` / tablespaces**

Ensure `MYSQLDUMP_OPTS=--no-tablespaces` is set on the `backup` service (included in current `docker-compose.yml`).

**Caddy / TLS issues**

```bash
docker compose logs caddy --tail=50
```

Check `DOMAIN`, DNS, and that nothing else binds ports 80/443.

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

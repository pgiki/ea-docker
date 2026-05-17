# Easy!Appointments — Makefile
# Shortcuts for common operations.

COMPOSE := $(shell docker compose version > /dev/null 2>&1 && echo "docker compose" || echo "docker-compose")

.PHONY: install update backup preflight fix-storage start stop restart logs logs-app logs-caddy shell-app shell-db status pull clean help

help:                  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install:               ## Download source and start the stack (first run)
	@bash scripts/install.sh

update:                ## Update to the latest release
	@bash scripts/update.sh

update-to:             ## Update to a specific version: make update-to VERSION=1.5.3
	@bash scripts/update.sh --version $(VERSION)

backup:                ## Run an on-demand database + storage backup
	@bash scripts/backup.sh

preflight:             ## Validate .env, DNS, and ports before deploy
	@bash scripts/preflight.sh

preflight-strict:      ## Preflight; fail on warnings (production gate)
	@bash scripts/preflight.sh --strict

fix-storage:           ## Seed empty app_storage volume (fixes HTTP 500)
	@bash scripts/fix-storage.sh

start:                 ## Start all services
	@$(COMPOSE) up -d

stop:                  ## Stop all services
	@$(COMPOSE) stop

restart:               ## Restart all services
	@$(COMPOSE) restart

logs:                  ## Tail logs from all services
	@$(COMPOSE) logs -f --tail=100

logs-app:              ## Tail app logs only
	@$(COMPOSE) logs -f --tail=100 app

logs-caddy:            ## Tail Caddy logs only
	@$(COMPOSE) logs -f --tail=100 caddy

shell-app:             ## Open a shell inside the app container
	@$(COMPOSE) exec app bash

shell-db:              ## Open a MySQL shell
	@$(COMPOSE) exec mysql mysql -u$${DB_USERNAME:-easyapp} -p$${DB_PASSWORD} $${DB_NAME:-easyappointments}

status:                ## Show running container status
	@$(COMPOSE) ps

pull:                  ## Pull latest Docker images
	@$(COMPOSE) pull

clean:                 ## Remove stopped containers (data volumes are preserved)
	@$(COMPOSE) down --remove-orphans

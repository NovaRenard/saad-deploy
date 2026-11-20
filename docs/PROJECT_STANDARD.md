# SAAD project standard

Every project deployed by SAAD Deploy — CRM, site, bot, internal service —
follows the same small contract. Meet it once and the project deploys itself on
every green push and shows up in the dashboard under its category.

```text
git push main ─► GitHub Actions (deploy.yml) green
                       │
     saad-deploy@<id>.timer (every 2 min) sees the new green SHA
                       │
     fetch ─► build ─► [backup DB] ─► [migrate] ─► start ─► health ─► commit
                       │
     saad-node-agent reports status ─► dashboard (Projects, by category)
```

## 1. What the repository must contain

| File | Requirement |
| --- | --- |
| `compose.yml` | Every long-running service has a `healthcheck`. Images built from source use `image: <name>:${IMAGE_TAG}` so each SHA gets its own tag. No `container_name`. No published ports except `127.0.0.1:<port>` for the host Nginx. |
| `.github/workflows/deploy.yml` | Runs on `push` to the deploy branch and must succeed only when the code is deployable (tests, lint, build). SAAD Deploy deploys the newest **successful push run** of this workflow. |
| `GET /healthz` (web services) | Returns 200 when the service is ready. Used by `HEALTH_URLS`. |
| `.env.production` | Lives **only on the server** in `APP_DIR`, never in Git. |

Optional, only when the project has them:

- a PostgreSQL service (auto-backed up with `pg_dumpall` before every deploy);
- a one-shot `migrate` service (run with `docker compose run --rm` before start);
- infrastructure services such as Redis that are started but not rebuilt.

Templates: [`templates/compose.site.yml`](../templates/compose.site.yml),
[`templates/compose.app-with-db.yml`](../templates/compose.app-with-db.yml),
[`templates/deploy.yml`](../templates/deploy.yml).

## 2. Categories

`APP_CATEGORY` groups projects in the dashboard:

| Category | Use for |
| --- | --- |
| `crm` | Client CRM installations. Only these can be assigned to organizations and shown in the client cabinet. |
| `site` | Landing pages, marketing and e-commerce sites. |
| `bot` | Telegram/WhatsApp bots and agents. |
| `service` | APIs and backends without their own UI. |
| `internal` | Your own tooling (the dashboard itself, admin tools). |
| `other` | Default when nothing is declared. |

## 3. Register a project on a server

```bash
# 1. Put the server-side env file in place (cloning happens automatically).
sudo install -d /srv/landing
sudo install -m 0600 /dev/stdin /srv/landing/.env.production <<'EOF'
NODE_ENV=production
EOF

# 2. One command: clone, detect services, write the contract, enable the poller.
sudo GITHUB_TOKEN=github_pat_xxx /opt/saad-deploy/bin/add-app.sh landing \
  --repo NovaRenard/landing \
  --dir /srv/landing \
  --name "Landing page" \
  --category site \
  --public-url https://landing.example \
  --health-url http://127.0.0.1:13000/healthz
```

`add-app.sh --print …` shows the generated contract without writing anything.
The contract is `/etc/saad-deploy/<id>.env` (root-owned, 0600); edit it if the
detected service lists need adjustment. The next agent heartbeat adds the
project to the dashboard; the next green push deploys it.

The GitHub token is a fine-grained token with read-only **Contents** and
**Actions** access to that one repository.

## 4. Contract reference

Required: `GITHUB_REPOSITORY GITHUB_WORKFLOW GITHUB_TOKEN DEPLOY_BRANCH APP_DIR
APP_ENV COMPOSE_FILE COMPOSE_PROJECT_NAME STATE_DIR BUILD_SERVICES APP_SERVICES
HEALTH_SERVICES HEALTH_URLS` (the last four may be empty lists).

Optional with defaults:

| Variable | Default |
| --- | --- |
| `APP_NAME` | app id |
| `APP_CATEGORY` | `other` |
| `PUBLIC_URL` | empty |
| `POSTGRES_SERVICE`, `MIGRATE_SERVICE` | empty — backup / migrations skipped |
| `INFRA_SERVICES`, `EXTRA_APP_SERVICES`, `REQUIRED_EXTERNAL_NETWORKS`, `COMPOSE_PROFILES` | empty |
| `BACKUP_DIR` | `$STATE_DIR/backups` |
| `BACKUP_RETENTION_DAYS` | `14` |
| `HEALTH_TIMEOUT_SECONDS` / `HEALTH_POLL_SECONDS` | `180` / `3` |
| `MANUAL_LOCK_WAIT_SECONDS` | `900` — how long a dashboard command waits for a running deployment |
| `DEPLOY_STRATEGY` | `recreate` (see README for `blue_green`) |

## 5. Checklist for a new project

- [ ] `compose.yml` with healthchecks and `${IMAGE_TAG}` image tags
- [ ] `deploy.yml` workflow green on `main`
- [ ] `/healthz` endpoint for web services
- [ ] `.env.production` on the server
- [ ] `add-app.sh <id> …` run once
- [ ] Project visible in the dashboard under the right category

## Monitored projects (`DEPLOY_MODE=monitor`)

Some things on a server are not built from one of your GitHub repositories:
third-party images (Evolution API, cloudflared) or a project whose CI is not
green yet. Register them so the dashboard still shows their containers and
alerts when they stop:

```env
DEPLOY_MODE=monitor
APP_ID=ecoenergy-evolution
APP_NAME="EcoEnergy WhatsApp (Evolution API)"
APP_CATEGORY=service
APP_DIR=/srv/services/evolution
COMPOSE_FILE=compose.yml
COMPOSE_PROJECT_NAME=ecoenergy-evolution
STATE_DIR=/var/lib/ecoenergy-evolution-deploy
# Optional: APP_ENV for Compose interpolation, APP_SERVICES to limit Restart.
```

Do not enable `saad-deploy@<id>.timer` for these contracts. Deploy, Apply
config and Rollback refuse with exit code 64; Restart runs
`docker compose restart` for the declared services (all when none are
declared). The dashboard judges a monitored project by its containers. To move
a project to automated deploys later, replace the contract with a full one and
enable its timer.

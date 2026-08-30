# SAAD Deploy v1

SAAD Deploy is a generic production deployment engine for multiple Docker Compose
applications. Deployment policy lives in this repository; each application only
provides an environment-file contract at `/etc/saad-deploy/<APP_ID>.env`.

The timer polls GitHub Actions. It deploys only the newest successful `push` run
for the configured deployment branch, verifies that exact SHA is reachable from
that branch, and then checks out the detached SHA. GitHub Actions never needs SSH
access to production.

## Install

Install this repository at `/opt/saad-deploy`, make scripts executable, and install
the units:

```bash
sudo install -d -m 0755 /opt/saad-deploy /etc/saad-deploy
sudo cp -a bin systemd README.md /opt/saad-deploy/
sudo chmod 0755 /opt/saad-deploy/bin/*.sh
sudo cp /opt/saad-deploy/systemd/saad-deploy@.service /opt/saad-deploy/systemd/saad-deploy@.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

The host needs Bash, `curl`, `jq`, Git, Docker Compose v2, `flock`, `gzip`, and
the ordinary core utilities. The service runs with the account that can access the
Docker daemon; the provided unit intentionally assumes root, which is the usual
production setup for the Docker socket.

Create one root-owned configuration file per application. Do not put this file in
the application repository.

```bash
sudo install -m 0600 /dev/stdin /etc/saad-deploy/example.env <<'EOF'
GITHUB_REPOSITORY=organization/repository
GITHUB_WORKFLOW=deploy.yml
GITHUB_TOKEN=replace-with-a-fine-grained-read-token
DEPLOY_BRANCH=main
APP_DIR=/srv/example
APP_ENV=.env.production
COMPOSE_FILE=compose.yml
COMPOSE_PROJECT_NAME=existing-production-project
STATE_DIR=/var/lib/saad-deploy/example
BACKUP_DIR=/var/backups/saad-deploy/example
BACKUP_RETENTION_DAYS=14
POSTGRES_SERVICE=database
INFRA_SERVICES="database cache"
BUILD_SERVICES="web worker migrate"
MIGRATE_SERVICE=migrate
APP_SERVICES="web worker"
EXTRA_APP_SERVICES=""
HEALTH_SERVICES="web worker"
REQUIRED_EXTERNAL_NETWORKS="shared-edge"
HEALTH_URLS="https://service.example/healthz"
COMPOSE_PROFILES="production"
EOF
```

`APP_ENV`, `COMPOSE_FILE`, `STATE_DIR`, and `BACKUP_DIR` may be absolute or
relative to `APP_DIR`. Service, network, profile, and URL lists are whitespace
separated. `HEALTH_TIMEOUT_SECONDS` (default `180`) and
`HEALTH_POLL_SECONDS` (default `3`) are optional timing controls.

`COMPOSE_PROJECT_NAME` is mandatory and is passed explicitly to every Compose
command. Set it to the existing production project name; the engine never guesses
or introduces a new project name.

## Deploy lifecycle

`saad-deploy@<APP_ID>.timer` starts about one minute after boot and every two
minutes thereafter. Enable it per application:

```bash
sudo systemctl enable --now saad-deploy@example.timer
sudo systemctl start saad-deploy@example.service
```

Useful commands:

```bash
sudo /opt/saad-deploy/bin/status.sh example
sudo /opt/saad-deploy/bin/deploy-sha.sh example <approved-sha>
sudo /opt/saad-deploy/bin/recreate.sh example
sudo /opt/saad-deploy/bin/rollback.sh example
```

The engine takes a non-blocking, application-specific lock. A concurrent trigger
exits with code `75` and does not modify state. It uses the exact service lists in
the config, verifies all configured external networks before starting anything,
waits for Docker healthchecks, and gates application startup on the migration
one-shot container.

Before migrations, it finds an existing `postgres_data` volume only by the Docker
Compose labels `com.docker.compose.project` and
`com.docker.compose.volume=postgres_data`. If found, it writes a compressed
`pg_dumpall` backup, retains it for `BACKUP_RETENTION_DAYS`, and never creates,
renames, or deletes a named volume.

State is held in `STATE_DIR` as `current-sha`, `previous-sha`, `deployed-at`,
`status.json`, and `last-error.log`. Files are written via same-directory temporary
files and atomic renames. A failure records `deploy_failed` and the failed step
without replacing `current-sha`.

## Restart, recreate, and deploy

The three operations intentionally have different scopes:

| Operation | What it does | What it never does |
| --- | --- | --- |
| `restart.sh <app-id>` | Runs `docker compose restart` for the root-owned `APP_SERVICES` and `EXTRA_APP_SERVICES` lists. | Does not recreate containers, read a new SHA, or apply changed compose/environment configuration. |
| `recreate.sh <app-id>` | Requires `current-sha`, checks out that exact local revision, exports `IMAGE_TAG`, validates Compose and external networks, then runs `docker compose up -d --force-recreate` for only application and extra application services. It waits for health checks and URLs. | Does not poll CI, build images, run migrations, start/recreate `INFRA_SERVICES`, or accept a caller-provided SHA/service/Compose argument. |
| `deploy-sha.sh <app-id> <sha>\|--query-ci` | Deploys a validated newer revision through the full build, backup, migration, infrastructure, application, and health-gated lifecycle. | Does not accept arbitrary shell or Docker input. |

`Restart != Recreate != Deploy`. Every operation loads the fixed root-owned
`/etc/saad-deploy/<APP_ID>.env` contract, validates the application ID, and
uses the same non-blocking per-application lock. `recreate.sh` writes a normal
operation result to `status.json`; a health failure remains nonzero and records
the failed step without changing `current-sha`.

## Migrating old project-specific timers

1. Inventory each legacy service and timer: repository path, branch, Compose
   project name, service groups, external networks, migration command, and health
   endpoints.
2. Stop and disable only that application's old timer and service. Keep its
   Compose installation, named volumes, and existing project name untouched.
3. Create `/etc/saad-deploy/<APP_ID>.env` using the existing absolute paths and
   the current `COMPOSE_PROJECT_NAME`. Put every application-specific decision in
   this file, not in `bin/` or `systemd/`.
4. Run `docker compose --project-name <existing-name> ... config -q` manually,
   then invoke `deploy-sha.sh <APP_ID> <known-good-sha>` once while watching
   `status.sh`. Confirm the detected backup and health endpoints before enabling
   the polling timer.
5. Enable `saad-deploy@<APP_ID>.timer`; only after a healthy run remove the old
   project-specific unit files. Do not delete named volumes as part of migration.

## Verification

Run `tests/check.sh`. It performs Bash syntax validation, runs ShellCheck when
available, and executes mocked end-to-end scenarios. GitHub Actions installs
ShellCheck and enforces the full suite on pushes and pull requests.

# SAAD Deploy v1

SAAD Deploy is a generic production deployment engine for Docker Compose
applications. Application-specific policy lives in a root-owned environment file
at /etc/saad-deploy/<APP_ID>.env. The engine contains no CRM-specific logic and
never evaluates shell commands supplied by that contract.

The poller deploys the newest successful GitHub Actions push run for the
configured branch, verifies its exact SHA, checks it out detached, and runs the
selected deployment strategy.

## Install

Install the repository at /opt/saad-deploy, make scripts executable, and install
the systemd units:

```bash
sudo install -d -m 0755 /opt/saad-deploy /etc/saad-deploy
sudo cp -a bin systemd README.md examples /opt/saad-deploy/
sudo chmod 0755 /opt/saad-deploy/bin/*.sh
sudo cp /opt/saad-deploy/systemd/saad-deploy@.service /opt/saad-deploy/systemd/saad-deploy@.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

The host needs Bash, curl, jq, Git, Docker Compose v2, flock, gzip, and
ordinary core utilities. The service normally runs as root so it can use the
Docker socket and manage the host Nginx include.

Copy and edit the example contracts as root-owned files:

```bash
sudo install -m 0600 examples/example.env /etc/saad-deploy/example.env
sudo install -m 0600 examples/example.blue.env /etc/saad-deploy/example.blue.env
sudo install -m 0600 examples/example.green.env /etc/saad-deploy/example.green.env
```

## Common configuration

Create one root-owned, mode-0600 file per application. Do not put it in the
application repository. The following variables are required by both modes:

```env
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
INFRA_SERVICES="database redis"
BUILD_SERVICES="backend frontend worker migrate"
MIGRATE_SERVICE=migrate
APP_SERVICES="backend frontend"
EXTRA_APP_SERVICES="worker"
HEALTH_SERVICES="backend frontend worker"
REQUIRED_EXTERNAL_NETWORKS="shared-edge"
HEALTH_URLS="https://service.example/healthz"
COMPOSE_PROFILES="production"
```

APP_ENV, COMPOSE_FILE, STATE_DIR, and BACKUP_DIR may be absolute or relative to
APP_DIR. Service, network, profile, and URL lists are whitespace separated.
HEALTH_TIMEOUT_SECONDS (default 180) and HEALTH_POLL_SECONDS (default 3) are
optional. If DEPLOY_STRATEGY is absent, it is recreate.

COMPOSE_PROJECT_NAME is always passed explicitly. Existing named volumes are
never deleted and the engine never runs docker compose down -v.

## recreate

recreate is the legacy strategy and remains the default. Its lifecycle is:

fetch -> checkout SHA -> build -> start infrastructure -> backup PostgreSQL ->
migrations -> start application -> Docker health -> URL health -> commit state

It uses the existing Compose project named by COMPOSE_PROJECT_NAME. Existing
applications that have no blue/green variables continue to use this mode.

## blue_green

Set DEPLOY_STRATEGY=blue_green and provide:

```env
DEPLOY_STRATEGY=blue_green
TRAFFIC_SERVICES="backend frontend"
TRAFFIC_HEALTH_SERVICES="backend frontend"
WORKER_SERVICES="automation-worker ai-agent-worker"
WORKER_HEALTH_SERVICES="automation-worker ai-agent-worker"
BLUE_ENV_FILE=/etc/saad-deploy/example.blue.env
GREEN_ENV_FILE=/etc/saad-deploy/example.green.env
BLUE_HEALTH_URLS="http://127.0.0.1:18080/healthz"
GREEN_HEALTH_URLS="http://127.0.0.1:18081/healthz"
NGINX_UPSTREAM_FILE=/etc/nginx/saad-deploy/example-upstream.conf
NGINX_BLUE_UPSTREAM=127.0.0.1:18080
NGINX_GREEN_UPSTREAM=127.0.0.1:18081
DRAIN_SECONDS=30
```

WORKER_SERVICES and WORKER_HEALTH_SERVICES may both be empty when an
application has no workers. DRAIN_SECONDS defaults to 30.

The stable infrastructure project remains exactly COMPOSE_PROJECT_NAME:

```text
existing-production-project
├── postgres / redis / migration infrastructure
├── persistent volumes
└── stable networks
```

Application slots use two separate Compose projects:

```text
existing-production-project-blue
└── traffic services / workers
existing-production-project-green
└── traffic services / workers
```

compose_infra uses the stable project. compose_slot blue and compose_slot green
use the corresponding project, the common APP_ENV, the slot env overlay, the
same Compose file, and immutable IMAGE_TAG. Slot services are started with
explicit service lists and --no-deps; the engine does not start PostgreSQL,
Redis, or any other infrastructure in a slot.

### Blue/green lifecycle

1. Read active-slot and choose the opposite slot. If no slot state exists,
   bootstrap uses blue as the first candidate without guessing an active slot.
2. Fetch, verify, checkout, validate, and build the target SHA once.
3. Keep stable infrastructure healthy without recreating existing containers.
4. Back up PostgreSQL from the stable project and run the new migration service
   against the stable database.
5. Start candidate traffic services only, then wait for candidate Docker health
   and direct server-local candidate URLs.
6. Atomically write the host Nginx upstream include, run nginx -t, and only
   then run systemctl reload nginx. Reload is graceful, never a restart.
7. Check public HEALTH_URLS.
8. Stop old workers, start candidate workers, and wait for worker health. Workers
   are not intentionally run in both versions during the drain period.
9. Drain old traffic for DRAIN_SECONDS, stop only old traffic services, and
   atomically commit state.

The upstream file is written through a same-directory temporary file and rename.
The configured file must already exist and must be below
/etc/nginx/saad-deploy/. The host Nginx configuration should include that file.

### Migration compatibility

The old slot continues serving traffic during candidate startup and migrations.
Blue/green migrations must therefore be backward-compatible with both releases.
Use the recommended expand -> deploy -> contract approach. SAAD Deploy never
performs a database downgrade.

### Automatic rollback

Before the Nginx switch, failures stop the candidate slot and leave production
traffic, current-sha, and active-slot unchanged. After a switch, failures
restore the previous upstream include, run nginx -t, reload Nginx, stop
candidate services, and restore old workers/traffic where possible. Public
health and worker health failures roll traffic back automatically.

rollback.sh prefers a fast rollback when the inactive slot contains
previous-sha and its traffic is already healthy. It switches traffic, checks
public health, switches workers, and commits state without rebuilding. If that
slot is absent or unhealthy, rollback runs the regular blue/green pipeline for
the previous SHA. No migration downgrade is attempted; an incompatible schema
must be handled manually.

## Application repository requirements

An application must be adapted to this contract before enabling blue/green:

- PostgreSQL, Redis, persistent volumes, and stable infrastructure are shared
  through the stable project; they are not duplicated per slot.
- Blue and green can run simultaneously with different host ports supplied by
  their server-owned env overlays.
- Compose has no conflicting fixed container_name; if names are explicit, they
  must be slot-dependent.
- Traffic services and worker services are separate, and all declared services
  exist in the Compose model.
- Slot services can reach stable infrastructure through external Docker
  networks or stable service endpoints.
- Candidate services expose direct server-local health endpoints that bypass
  public Nginx routing.
- Migrations are backward-compatible with old and new application versions.
- The Compose contract does not require the engine to rewrite services, networks,
  volumes, ports, or dependencies. SAAD Deploy does not rewrite app Compose.

Validation rejects unsupported strategies, missing slot env files, unsafe Nginx
targets or paths, equal slot targets, invalid project names, missing services,
infra services included in slot lists, conflicting fixed container names, and
detectable shared host ports. Lists are passed as arrays; no eval or config
provided reload command is used.

## Restart, recreate, and rollback behavior

| Operation | recreate | blue_green |
| --- | --- | --- |
| restart.sh | Restart APP_SERVICES and EXTRA_APP_SERVICES in the stable project. | Restart only active-slot traffic and worker services. |
| recreate.sh | Recreate only application services at current-sha. | Recreate only active-slot application services; never switch slot or SHA. |
| rollback.sh | Deploy previous-sha through the legacy lifecycle. | Prefer fast inactive-slot switch; otherwise use the regular blue/green pipeline. |
| deploy-sha.sh | Full legacy lifecycle. | Candidate lifecycle, traffic switch, worker switch, drain, and state promotion. |

restart.sh does not read a new SHA, recreate containers, or write deployment
status. recreate.sh does not poll CI, build images, run migrations, or recreate
stable infrastructure. The deployment lock is application-specific and
non-blocking; contention exits with code 75 without changing state.

## State and status

STATE_DIR contains current-sha, previous-sha, deployed-at, status.json,
last-error.log, and, for blue/green, active-slot, blue-sha, and green-sha.
Each file is written with a same-directory temporary file and atomic rename.
Promotion files are not changed until candidate, traffic, public health,
workers, and drain phases succeed.

status.json reports strategy, current SHA, previous SHA, active slot, candidate
slot, blue SHA, green SHA, current deployment step, and last error. Blue/green
steps include determining_slots, preparing_candidate, waiting_candidate_health,
checking_candidate_urls, switching_traffic, checking_public_health,
switching_workers, draining_previous_slot, stopping_previous_slot, and
committing_state.

## Useful commands

```bash
sudo systemctl enable --now saad-deploy@example.timer
sudo systemctl start saad-deploy@example.service
sudo /opt/saad-deploy/bin/status.sh example
sudo /opt/saad-deploy/bin/deploy-sha.sh example <approved-sha>
sudo /opt/saad-deploy/bin/recreate.sh example
sudo /opt/saad-deploy/bin/rollback.sh example
```

## Migrating existing applications

For an existing application, keep its Compose project name, repository checkout,
named volumes, and external networks unchanged. Put its current service lists
and health URLs in `/etc/saad-deploy/<APP_ID>.env`, run one known-good SHA
manually, inspect `status.sh`, and enable the generic timer only after a healthy
result. Do not delete the old volumes as part of the migration. Enable
blue/green only after the application repository satisfies the requirements
above and both slot overlays have been tested.

## Examples and verification

Ready-to-copy example contracts are in examples/example.env,
examples/example.blue.env, and examples/example.green.env. The example main
file demonstrates blue/green; omit the strategy and use APP_SERVICES,
EXTRA_APP_SERVICES, and HEALTH_SERVICES for legacy recreate applications.

Run:

```bash
tests/check.sh
```

This performs Bash syntax validation, runs ShellCheck when installed, and runs
mocked end-to-end scenarios for legacy compatibility, both promotion directions,
bootstrap, candidate health failures, Nginx failures, public health rollback,
worker rollback, state atomicity, validation, and fast rollback.

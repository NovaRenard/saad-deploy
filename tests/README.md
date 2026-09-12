# Tests

Run all local checks with:

```bash
tests/check.sh
```

`check.sh` always runs Bash syntax validation and the deployment scenarios. It also
runs ShellCheck when `shellcheck` is installed. CI installs ShellCheck, so linting
is mandatory there.

The scenario suite replaces Docker, GitHub, Git, flock, Nginx, and systemctl
with small command mocks. It covers no-op deployments, failed CI, lock
contention, build/migration/health failures, successful legacy promotion, both
blue/green promotion directions, bootstrap, candidate Docker/HTTP health
failures, Nginx test/reload failures, public health rollback, worker rollback,
state-write atomicity, strict validation, and fast rollback without a rebuild.

# Tests

Run all local checks with:

```bash
tests/check.sh
```

`check.sh` always runs Bash syntax validation and the deployment scenarios. It also
runs ShellCheck when `shellcheck` is installed. CI installs ShellCheck, so linting
is mandatory there.

The scenario suite replaces Docker, GitHub, Git, and `flock` with small command
mocks. It covers no-op deployments, failed CI, lock contention, build/migration/
health failures, successful promotion, atomic status writes, and preservation of
the prior `current-sha` after failures.

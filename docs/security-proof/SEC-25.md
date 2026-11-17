# SEC-25 — Vulnerable transitive dependency shell-quote

Severity: Critical (npm audit). Package: `shell-quote` (transitive via npm-run-all2).

The lockfile pinned shell-quote 1.8.3, affected by a critical newline-escape
advisory and a high DoS advisory.

## RED (before fix)

```
pnpm audit --json  (src/apps/desktop)
shell-quote advisories BEFORE: [('1120422', 'critical'), ('1123944', 'high')]
```

## GREEN (after fix)

Added a pnpm override in `pnpm-workspace.yaml` (pnpm 12 reads overrides there,
not in package.json) pinning shell-quote to 1.11.0, and refreshed the lockfile.

```
pnpm audit --json
shell-quote advisories AFTER 1.11.0: []
```

Lockfile diff: shell-quote 1.8.3 -> 1.11.0 (integrity updated), 12 lines changed.

## Re-scan

`pnpm audit` reports zero shell-quote advisories. No new advisories introduced
by the bump (the override is a single transitive package).

## Gates

- pnpm run lint:check: 0 errors (87 pre-existing warnings)
- zig build: green
- zig build test: green (6148 pass, 4 skip, 0 fail)
- test:desktop-app: pre-existing WebKit/GPU environment failure, reproduced on
  clean main with the change stashed — not caused by this fix

# SEC-26 — High-severity transitive dependency advisories

Severity: High (npm audit). Packages: undici, nanoid, browserslist, js-cookie,
postcss, source-map-js (all transitive in `src/apps/desktop`).

The lockfile pinned versions affected by high-severity advisories (TLS validation,
DoS, prototype hijack, path traversal, etc.).

## RED (before fix)

```
pnpm audit --json  (src/apps/desktop)
metadata.vulnerabilities: {low:8, moderate:31, high:31, critical:0}
undici: 29 advisories, nanoid: 3, postcss: 3, browserslist: 2, js-cookie: 1, source-map-js: 1
```

## GREEN (after fix)

Added same-major patch/minor overrides in `pnpm-workspace.yaml` and refreshed the
lockfile. `@vue/server-renderer` was deliberately NOT overridden: its patched
3.5.42 would skew against the app's `vue@3.5.32`.

```
pnpm audit --json
metadata.vulnerabilities: {low:3, moderate:16, high:12, critical:0}
cleared: undici 29->0, nanoid 3->0, browserslist 2->0, js-cookie 1->0,
         source-map-js 1->0, postcss 3->1, baseline-browser-mapping 1->0
```

## Re-scan

`pnpm audit` reports 19 fewer advisories (70 -> 51) and no new advisory classes.
Remaining: brace-expansion (13), vite (7), postcss-selector-parser (2), and a few
others — need larger upgrades, reported only.

## Gates

- pnpm run lint:check: 0 errors (87 pre-existing warnings)
- pnpm run test:unit: 701 files / 6647 tests passed
- zig build: green; zig build test: 6148 pass, 4 skip, 0 fail
- clean test output: green
- diff: 114 changed lines (lockfile + workspace yaml), no secrets

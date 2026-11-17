# SEC-23 — Unvalidated workspace item path

Severity: Medium. File: `src/http_handlers/workspace_items_create.zig:63`.

A client-supplied item `path` was stored verbatim; `/`, a drive root, `~...`,
or a path with `..` could hand sessions under that item an over-broad sandbox root.

## RED (before fix)

Stub `validateItemPath` returned null for everything; 6 behavior tests added.

```
zig build test -Dtest-shards=1
+- test mod_tests (all 6555) 6144 pass, 4 skip, 4 fail (6152 total)
error: '...validateItemPath rejects a filesystem root' failed
error: '...validateItemPath rejects a Windows drive root' failed
error: '...validateItemPath rejects parent traversal segments' failed
error: '...validateItemPath rejects an unexpanded home reference' failed
```

## GREEN (after fix)

```
zig build test -Dtest-shards=1 --summary all
+- test mod_tests (all 6555) 6148 pass, 4 skip (6152 total) 0 fail
```

Fix: `validateItemPath` rejects empty, filesystem/drive roots, `~` refs and `..`
segments; `useCase` returns `error.InvalidPath` (HTTP 400). Normal paths pass.

## Re-scan

`grep -n validateItemPath src/http_handlers/workspace_items_create.zig` shows the
guard wired into `useCase` (line 63) plus 6 passing behavior tests. No new
findings from the secret scan (`/tmp/scan_before.txt`).

## Gates

- build: green
- full tests: 6148 pass, 4 skip, 0 fail (baseline 6144 pass, 4 skip, 4 pre-existing RED from the new tests)
- zginlint: only the pre-existing generated-file finding remains
- clean test output: green


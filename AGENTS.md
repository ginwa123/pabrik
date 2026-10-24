
#Mandatory
DONT KILL THE PORT 8081 SERVER,
for testing use another port like 8080

#Proof
No need to push docs. Proof of work belongs in the PR body — curl transcripts,
test output, accessibility and computed-style evidence — not committed under
`docs/`. Screenshots and notes stay out of the diff.

#Clean test output
`zig build test` MUST print no logger line and no `failed command:` block on a
green run — only build.zig's own `[test]` header. Zig relays ANY stderr from a
PASSING test as a `run test w` block, which has the exact shape of a failure
without the failing test's name or counts, so the next agent hunts a bug that
is not there. Fix the site, never the log: a warn a test can reach goes through
the global Logger (`if (loggermod.getGlobal()) |logger| logger.warnFmt(…)`),
a raw print through `Logger.debugPrint(…)`. A failing run is exempt — it names
the test and the shard (`test mod_tests shard 3/8 (731 tests) 2 pass, 1 fail`).
Enforced by `scripts/check-zig-test-output-clean.sh` in CI; run it locally with
`--run`, or judge an existing log with `--summary <log>`.

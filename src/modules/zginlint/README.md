# zginlint

A linter for Zig source, in the shape of ESLint: a lexer, a set of rules
that read it, a report, and a pin file that lets a rule be enforced on a
tree that has not been converted yet.

It lives at `src/modules/zginlint/` as a **standalone** module — std only,
not part of the `pabrikcore` module graph — so it compiles without the
app's dependency stack and can grow into a library of its own.

## Use it

```bash
zig build zginlint                       # build zig-out/bin/zginlint
zig-out/bin/zginlint src tests           # report every finding, exit 1 if any
zig-out/bin/zginlint --max-comment-lines 2 src
zig build zginlint:check                 # the gate CI runs (pinned ceilings)
zig build zginlint:pin                   # re-pin the baseline to today's counts
zig build test:zginlint                  # the linter's own tests
```

`zginlint --help` prints the whole surface. Exit codes are part of the
contract: `0` clean or within the pinned ceilings, `1` findings, `2` a
usage or I/O error — a path the tool could not read never reads as "the
tree is clean".

## The rules

### `zginlint/max-comment-lines`

A comment block may not exceed **3 lines** (`--max-comment-lines N`).

- A **comment line** carries comment content and no code byte.
- A **comment block** is a run of consecutive comment lines. A blank line
  or a line with code on it ends the block.
- A block longer than the ceiling produces one finding, at the block's
  first line: `src/a.zig:12:1: error Comment block has 7 lines; max is 3
  (zginlint/max-comment-lines)`.
- `///` doc comments and `//!` container docs are comments like any other
  and get no exemption.
- A trailing comment after code (`const x = 1; // note`) is not a block and
  is never counted.
- Comment markers inside a string or char literal, and inside a multi-line
  string fenced with `\\`, are text, not comments.
- Block comments nest, and `/* ... */` counts by the lines it spans.

### `zginlint/no-catch-unreachable`

The banned error-handling pair — the same rule as
`scripts/lint-no-catch-unreachable.sh`, and the reason
`CODING_STANDARDS.md` §1 exists: it panics with no usable message in
Debug/ReleaseSafe and is **undefined behaviour** in ReleaseFast.

- The finding is reported at the `catch`, with the column that starts it.
- The scan is over **raw bytes**, exactly like the ripgrep lint it mirrors,
  so a commented-out site counts (§1 asks for that) and so does one inside
  a string literal. There is no token-level exemption to argue about.
- One or more whitespace bytes are allowed between the two words, newlines
  included, so a wrapped `catch` / `unreachable` pair is still caught.
- A word boundary is required after it, so `somethingUnreachable` is not a
  hit; `catch @panic("...")` is the sanctioned form and is not one either.
- It takes no options, and its fingerprint is `-`.

## The baseline ratchet

The tree already contains thousands of long comment blocks (see
`CODING_STANDARDS.md` §4), so the gate does not ask for zero — it asks for
**no worse than pinned**. `zginlint-baseline.json` records, per rule, a
ceiling for every file that has findings, plus the path set and the options
the counts were measured with. `zig build zginlint:check` fails when:

- a file's count is above its pinned ceiling, or
- a file with findings is not pinned at all (a new file cannot sneak in).

A count that fell is printed as a `note ... re-pin with --update-baseline`
and passes, so a ceiling can only ever be tightened. A rule with **no pin
entry** has a ceiling of zero, which is how `no-catch-unreachable` ships:
the tree had 20 sites in `tests/`, `tools/` and `build.zig` when the rule
landed, and they were converted rather than pinned.

A check whose path set, or whose options fingerprint for any rule, differs
from the pin's is **refused** (`exit 2`) rather than compared against the
wrong numbers. `zig build zginlint:pin` regenerates the file from today's
counts, sorted by path and keyed by rule. Re-pin only to tighten, and in
the same change that tightened it.

## Layout

| file | what it owns |
|---|---|
| `comment_scan.zig` | the lexer: source bytes in, comment lines and blocks out |
| `rules/max_comment_lines.zig` | the comment-block ceiling |
| `rules/no_catch_unreachable.zig` | the banned error-handling pair |
| `diagnostic.zig` | a finding and the message its rule wrote |
| `rule.zig` | what a rule is: id, options fingerprint, check |
| `options.zig` | the options every rule is read with |
| `zginlint.zig` | the engine: the rule list, `lintSource`, the tree walk, the ordering |
| `baseline.zig` | the pin's format and the ratchet comparison |
| `cli.zig` | argv parsing, the report, the exit codes |
| `main.zig` | the thin exe entry point |
| `test_root.zig` | the test root `zig build test:zginlint` runs |

Adding a rule: put it in `rules/`, give it a field in `options.zig` if it
needs one, add its declaration to `zginlint.rules`, and add its path to
`test_root.zig`.

## Where it runs

`.github/workflows/ci.yml` has a `zginlint` job (hanging off the cheap
`lint` job) that runs `zig build zginlint:check`, and `.husky/pre-commit`
mirrors that one command. The linter's own tests are part of `zig build
test`, so every backend cell of CI runs them on Linux, macOS and Windows.

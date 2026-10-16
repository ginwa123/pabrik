# Comment-length policy — a block is at most three lines

`local/max-comment-lines` caps a comment block at three lines. Pre-existing
blocks are pinned as baseline debt in `eslint-suppressions.json` (3,822
blocks across 733 files). The baseline only shrinks: regenerate with
`pnpm run lint:banned-baseline` **after fixing debt, never to silence a
violation**.

This is the Vue/TS half of `CODING_STANDARDS.md` §4, whose Zig half is
`zginlint/max-comment-lines`. Same ceiling, same semantics, same reason —
the rule is about comments, not about a language.

## Why a ceiling at all

A comment block is a paragraph, and a paragraph in the middle of a function
grows until the code is off the screen. ESLint's `max-len` makes the same
bet one level down: a number small enough that nobody argues with it,
enforced by a machine, so that "this comment is too long" stops being a
review comment.

Three lines is enough for the *why* — which operation this is guarding,
which invariant it is relying on — and not enough to smuggle a design
document into a function body. The design document goes where it can be
found: `docs/`, the commit message, the module README.

## The rule

- A **comment line** carries comment content and no code byte, so a blank
  line or a line with code on it ends the block.
- A **comment block** is a run of consecutive comment lines. Three lines
  pass, four fail, and the finding is reported at the block's first line.
- A `/* ... */` comment counts by the lines it spans, nested or not.
- `/** ... */` JSDoc counts like any other comment. There is no doc-string
  exemption.

## What stays legal

- **Comments.** The rule is about length, not existence. A three-line
  comment explaining a non-obvious invariant is what it is trying to
  produce.
- **A trailing comment after code.** `const x = 1 // note` has a code byte
  on its line, so it is not a comment line and never joins a block.
- **Comment markers inside a literal.** `"// not a comment"` and a template
  literal holding `/*` are text. ESLint's lexer already knows the
  difference, so the rule inherits it rather than reimplementing a scanner.

## What is NOT scanned — two known gaps

These are named so nobody mistakes "not scanned" for "not a problem".

| Surface | Why |
|---|---|
| HTML comments in `<template>` | Reachable — `vue-eslint-parser` exposes them as `HTMLComment` nodes under `templateBody` — but 464 of the 1,107 here are multi-line template prose explaining a branch of the view chain. Capping them means rewriting 153 files, which is the unreviewable whole-repo diff §4 avoided with a baseline. |
| CSS comments in `<style>` | Unreachable: `vue-eslint-parser` does not parse the style block at all, so there is no AST to read and no honest way to count them. 102 exist, 72 of them multi-line. |

## How to fix a finding

1. **Shorten it.** Keep the three lines that say why. The rest is usually
   history — which plan it came from, what the previous design was — and
   history belongs in the commit message or `docs/`.
2. **Split it.** A blank line ends a block, so two three-line blocks are
   legal where one six-line block is not. Use this when the comment really
   does cover two separate things.
3. **Move it.** If the comment is a design document, it belongs in `docs/`
   or the module README, where it is read once instead of sitting between
   the reader and the code.
4. **Delete it.** If it restates the code, or describes a bug that is
   fixed, or names a plan that shipped, it is noise.

Then re-pin: `pnpm run lint:banned-baseline`. The count for that file drops
by one and the gate stays green.

## Exemption process

There is no inline exemption. A block that genuinely needs four lines is a
signal that the prose belongs somewhere else, so the fix is to move it —
not to suppress the rule. If a case truly cannot be shortened, split, moved
or deleted, bring it to review with the block and the reason.

Never regenerate the baseline to silence a new violation.

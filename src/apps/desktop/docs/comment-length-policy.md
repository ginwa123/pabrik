# Comment-length policy — a block is ONE line

`local/max-comment-lines` caps a comment block at one line. The debt that
made this rule ship with a baseline is gone — the last 6,966 blocks were
collapsed to a single line each — so the rule has **no suppression entry**
in `eslint-suppressions.json` and a finding is a finding. `eslint-suppressions.json`
still pins the *other* banned-code rules; regenerating it is
`pnpm run lint:banned-baseline`, **after fixing debt, never to silence a
violation**.

This is the Vue/TS half of `CODING_STANDARDS.md` §4, whose Zig half is
`zginlint/max-comment-lines` and whose Kotlin half is
`scripts/lint-kt-comment-lines.py`. Same ceiling, same semantics, same
reason — the rule is about comments, not about a language.

## Why a ceiling at all

A comment block is a paragraph, and a paragraph in the middle of a function
grows until the code is off the screen. ESLint's `max-len` makes the same
bet one level down: a number small enough that nobody argues with it,
enforced by a machine, so that "this comment is too long" stops being a
review comment.

One line is enough for the *why* — which operation this is guarding, which
invariant it is relying on — and not enough to smuggle a design document
into a function body. The design document goes where it can be found:
`docs/`, the commit message, the module README.

**Why one and not three.** A three-line block was usually one sentence of
preamble, one sentence carrying the fact, and one recording history that
`git log` already answers. A ceiling of one forces that judgement at write
time. The cost is real: the third sentence of a genuinely three-sentence
explanation now lives in a commit message, and finding it takes
`git log -L`. That is the trade.

## The rule

- A **comment line** carries comment content and no code byte, so a blank
  line or a line with code on it ends the block.
- A **comment block** is a run of consecutive comment lines. One line
  passes, two fail, and the finding is reported at the block's first line.
- A `/* ... */` comment counts by the lines it spans, nested or not.
- `/** ... */` JSDoc counts like any other comment. There is no doc-string
  exemption.

## What stays legal

- **Comments.** The rule is about length, not existence. A one-line comment
  naming a non-obvious invariant is what it is trying to produce.
- **A trailing comment after code.** `const x = 1 // note` has a code byte
  on its line, so it is not a comment line and never joins a block.
- **Comment markers inside a literal.** `"// not a comment"` and a template
  literal holding `/*` are text. ESLint's lexer already knows the
  difference, so the rule inherits it rather than reimplementing a scanner.
- **A directive.** `// eslint-disable-next-line …`, `// @ts-expect-error`,
  `/// <reference types="vite/client" />` are instructions a tool reads, not
  prose. They survive the ceiling verbatim, and a whole-file
  `/* eslint-disable … */` must stay a BLOCK comment — ESLint ignores that
  directive in a `//` comment, which would be a green gate that checks
  nothing.

## What is NOT scanned — two known gaps

These are named so nobody mistakes "not scanned" for "not a problem". Both
survived the one-line pass untouched, deliberately.

| Surface | Why |
|---|---|
| HTML comments in `<template>` | Reachable — `vue-eslint-parser` exposes them as `HTMLComment` nodes under `templateBody` — but they are multi-line template prose explaining a branch of the view chain. Capping them means rewriting 153 files, which is the unreviewable whole-repo diff §4 avoided with a baseline. |
| CSS comments in `<style>` | Unreachable: `vue-eslint-parser` does not parse the style block at all, so there is no AST to read and no honest way to count them. |

## How to fix a finding

1. **Shorten it.** Keep the one line that says why. The rest is usually
   history — which plan it came from, what the previous design was — and
   history belongs in the commit message or `docs/`.
2. **Move it.** If the comment is a design document, it belongs in `docs/`
   or the module README, where it is read once instead of sitting between
   the reader and the code.
3. **Delete it.** If it restates the code, or describes a bug that is
   fixed, or names a plan that shipped, it is noise.

Splitting a paragraph into several one-line comments is NOT a fix. The
ceiling counts a block, but `local/no-floating-comments` bans the shape that
would otherwise make splitting trivial — a comment separated from its code
by a blank line — and the honest answer is that the paragraph had exactly
one load-bearing sentence.

## Exemption process

There is no inline exemption. A block that genuinely needs two lines is a
signal that the prose belongs somewhere else, so the fix is to move it — not
to suppress the rule. If a case truly cannot be shortened, moved or deleted,
bring it to review with the block and the reason.

Never regenerate the baseline to silence a new violation.

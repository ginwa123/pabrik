/**
 * `local/max-comment-lines` — a comment block may span at most three lines.
 *
 * The Vue/TS half of CODING_STANDARDS.md §4, whose Zig half is
 * `zginlint/max-comment-lines`. Same ceiling, same semantics, same reason:
 * a comment block is a paragraph, and a paragraph in the middle of a
 * function grows until the code is off the screen.
 *
 * A comment line carries comment content and no code byte, so a blank line
 * or a code line ends a block and a trailing comment never joins one. A
 * `/* ... *\/` comment counts by the lines it spans.
 *
 * OUT OF SCOPE, each a documented gap in CODING_STANDARDS.md §5 rather
 * than a silent one: HTML comments in `<template>` (464 of 1,107 are
 * multi-line template prose) and CSS comments in `<style>` (72 of 102 —
 * `vue-eslint-parser` does not parse the style block, so there is no AST
 * to read). Comment markers inside a literal are text; ESLint's lexer
 * already knows the difference, so this rule inherits that for free.
 *
 * WHY ESLINT AND NOT A SCRIPT: the frontend already has a per-file count
 * ratchet (`eslint --suppress-rule` + `eslint-suppressions.json`) that
 * `local/no-try-catch` and `local/no-watch` ride. A second baseline format
 * for the same job would be a second thing to maintain and to get wrong.
 *
 * `docs/comment-length-policy.md` is the working companion: how to fix a
 * finding, what stays legal, and why there is no inline exemption.
 */
import type { Rule } from 'eslint'

/** Three lines, matching `zginlint/max-comment-lines`'s default. */
const DEFAULT_MAX_LINES = 3

/** A comment as ESLint's lexer reports it: `Line` or `Block`, with a range. */
type Comment = {
  type: 'Line' | 'Block'
  loc: { start: { line: number; column: number }; end: { line: number; column: number } }
}

/** A run of consecutive comment lines, reported at its first line. */
type Block = { firstLine: number; lineCount: number }

/** True when `text` is empty or nothing but whitespace. */
function isBlank(text: string): boolean {
  return text.trim().length === 0
}

/**
 * The line numbers a comment occupies that carry comment content and no
 * code byte — the same test `zginlint`'s lexer applies.
 *
 * A `Line` comment is one line, and it counts only when nothing but
 * whitespace precedes it: `const x = 1 // note` has a code byte on that
 * line, so the line is not a comment line and the comment never joins a
 * block. A `Block` comment counts its first line only when nothing precedes
 * it, its last line only when nothing follows it, and every line between
 * unconditionally.
 */
function commentLinesOf(comment: Comment, lines: readonly string[]): number[] {
  const first = comment.loc.start.line
  const last = comment.loc.end.line
  const out: number[] = []

  const before = isBlank((lines[first - 1] ?? '').slice(0, comment.loc.start.column))
  const after = isBlank((lines[last - 1] ?? '').slice(comment.loc.end.column))

  if (first === last) {
    if (before && after) out.push(first)
    return out
  }
  if (before) out.push(first)
  for (let line = first + 1; line < last; line++) out.push(line)
  if (after) out.push(last)
  return out
}

/**
 * Group ascending comment-line numbers into blocks, exactly as
 * `zginlint/comment_scan.zig` does: a line continues the previous block
 * when it is the very next line, and otherwise opens a new one.
 */
function blocksFromLines(lineNumbers: number[]): Block[] {
  const blocks: Block[] = []
  for (const line of lineNumbers) {
    const previous = blocks[blocks.length - 1]
    if (previous && previous.firstLine + previous.lineCount === line) {
      previous.lineCount += 1
    } else {
      blocks.push({ firstLine: line, lineCount: 1 })
    }
  }
  return blocks
}

export const maxCommentLines: Rule.RuleModule = {
  meta: {
    type: 'suggestion',
    docs: {
      description:
        'Disallow comment blocks longer than three lines — the extra sentences belong in docs/, the commit message or the PR body.',
    },
    schema: [
      {
        type: 'object',
        properties: {
          max: { type: 'integer', minimum: 1 },
        },
        additionalProperties: false,
      },
    ],
    messages: {
      maxCommentLines:
        'This comment block spans {{actual}} lines; the ceiling is {{max}}. A comment block is a paragraph, and a paragraph in the middle of a function grows until the code is off the screen. Keep the three lines that say WHY — which operation this guards, which invariant it relies on — and move the rest to `docs/`, the commit message or the PR body, where it is read once instead of sitting between the reader and the code. (CODING_STANDARDS.md §4; the Zig half is `zginlint/max-comment-lines`.)',
    },
  },
  create(context) {
    const options = (context.options[0] ?? {}) as { max?: number }
    const max = options.max ?? DEFAULT_MAX_LINES

    const source =
      context.sourceCode ?? (context as never as { getSourceCode(): never }).getSourceCode()

    return {
      Program() {
        const comments = source.getAllComments() as unknown as Comment[]
        const lines = source.lines ?? []

        // Collect every comment line in the file, then group. Two passes
        // rather than per-comment keeps a block that mixes shapes
        // (`/* … */` followed by `//`) in one group, which is what the Zig
        // rule does and what a reader sees as one paragraph.
        const lineNumbers: number[] = []
        for (const comment of comments) {
          for (const line of commentLinesOf(comment, lines)) lineNumbers.push(line)
        }
        lineNumbers.sort((a, b) => a - b)

        for (const block of blocksFromLines(lineNumbers)) {
          if (block.lineCount <= max) continue
          context.report({
            loc: {
              start: { line: block.firstLine, column: 1 },
              end: { line: block.firstLine, column: 1 },
            },
            messageId: 'maxCommentLines',
            data: { actual: String(block.lineCount), max: String(max) },
          })
        }
      },
    }
  },
}

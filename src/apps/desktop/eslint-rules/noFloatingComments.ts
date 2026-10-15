/**
 * `local/no-floating-comments` — a comment must attach to the code it explains.
 *
 * `local/max-comment-lines` caps a comment block at three lines. The obvious
 * way to satisfy that cap is to cut one long comment into several three-line
 * blocks separated by blank lines, which is exactly what happened while paying
 * that debt down:
 *
 *     // Alias the key rather than mirroring it into a local ref. This used to be `const keyRef =
 *     // ref(initialKey)` plus a `{ immediate: true }` watcher copying `storageKey.value` into it.
 *
 *     // The watcher needed the `immediate` flag precisely because the snapshot could not see the
 *     // current value on its own, and it still could not cover a key that changed between setup and the
 *     // first flush.
 *
 *     // Aliasing reads the live value every time, so a dynamic key is correct from the first access and
 *     // no watcher is needed at all.
 *     const keyRef: Ref<string> = typeof storageKey === 'string' ? ref(storageKey) : storageKey
 *
 * Nine lines of prose, three findings instead of one, and the reader now has to
 * reassemble the paragraphs by eye. The ceiling exists to keep a paragraph from
 * growing until the code is off the screen; splitting it into floating
 * paragraphs keeps every word on the screen and defeats the point.
 *
 * THE RULE: a comment block is FLOATING when the line after it is blank and the
 * chain of blank-separated lines ends at a line of CODE. That covers both
 * shapes:
 *
 *   - comment, blank, code — the comment floats above the code.
 *   - comment, blank, comment, blank, code — one comment cut into pieces, each
 *     piece floating above the same code. Every piece is reported.
 *
 * A chain that ends at a blank line, a closing brace, or the end of the file is
 * NOT floating: there is no code underneath it to attach to.
 *
 * WHAT IS STILL LEGAL, deliberately:
 *
 *   - A comment at the very end of a file, or before a blank line that is
 *     followed by another blank line or by a closing brace. There is no code
 *     underneath it to attach to, so there is nothing to cheat.
 *   - A comment above a blank line that separates two top-level declarations,
 *     where the comment belongs to the declaration BELOW the blank. That is the
 *     ordinary "section header" shape and it is not a split.
 *   - A trailing comment after code (`const x = 1 // note`). It has a code byte
 *     on its line, so it is attached by construction.
 *   - A comment inside a block that is followed by a blank line and then more
 *     code in the SAME block. The blank line is the author's paragraph break
 *     inside one logical comment, and the code it explains is still below.
 *
 * WHY A LINE-BASED RULE AND NOT AN AST ONE: the thing being detected is the
 * SHAPE of the source — where the blank lines sit relative to the comment and
 * the code — and that shape is not in the AST. `sourceCode.lines` is the honest
 * input, the same one `local/max-comment-lines` already uses.
 */
import type { Rule } from 'eslint'

/** A line that starts a comment: `//`, `///`, `/*` or a JSDoc `*` continuation. */
const COMMENT_LINE = /^[ \t]*(?:\/\/|\/\*|\*)/
/** A line that starts a statement or a member: the thing a comment attaches to. */
const CODE_LINE = /^[ \t]*(?:[A-Za-z_$@})\]]|[`'"])/

export const noFloatingComments: Rule.RuleModule = {
  meta: {
    type: 'suggestion',
    docs: {
      description:
        'Disallow comment blocks separated from their code by a blank line — a comment must attach to the code it explains, not float above it.',
    },
    schema: [],
    messages: {
      floating:
        'This comment block is separated from the code it explains by a blank line, so it reads as a floating paragraph rather than as documentation for the line below it. Either move it down to touch the code, or — if it really is a standalone note — say so in a form that is not a paragraph cut into pieces: `docs/`, the commit message, or the PR body. Splitting one long comment into several three-line blocks to satisfy `local/max-comment-lines` is the shape this rule exists to stop.',
    },
  },
  create(context) {
    const sourceCode =
      context.sourceCode ?? (context as never as { getSourceCode(): never }).getSourceCode()
    const lines = (sourceCode.lines ?? []) as readonly string[]
    const total = lines.length

    /** True when `text` is empty or nothing but whitespace. */
    const isBlank = (text: string): boolean => text.trim().length === 0
    const isComment = (text: string): boolean => COMMENT_LINE.test(text)
    const isCode = (text: string): boolean => CODE_LINE.test(text)

    return {
      Program() {
        // Walk the file line by line. A comment RUN is a maximal set of
        // consecutive comment lines.
        let index = 0
        while (index < total) {
          if (!isComment(lines[index] ?? '')) {
            index += 1
            continue
          }

          const runStart = index
          while (index < total && isComment(lines[index] ?? '')) index += 1
          const runEnd = index // exclusive

          // Follow the chain of blank-separated lines that starts right after
          // this run. The chain is: blank lines, then either another comment
          // run (keep going) or a terminating line (stop).
          // Count the blank lines that follow the run. Exactly ONE blank line
          // separates a comment from the code it was cut away from; two or
          // more is a section break between declarations, which is a different
          // thing and is not this rule's business.
          let cursor = runEnd
          let blankCount = 0
          while (cursor < total && isBlank(lines[cursor] ?? '')) {
            blankCount += 1
            cursor += 1
          }
          const sawBlank = blankCount === 1

          // No blank after the run means the comment touches whatever follows,
          // so it is attached by construction.
          let chainEnd = runEnd
          if (sawBlank) {
            // Walk the chain, collecting every comment run in it. The chain is
            // comment runs joined by blank lines; it stops at the first line
            // that is neither a comment nor a blank.
            const runStarts = [runStart]
            let chain = cursor
            while (chain < total && isComment(lines[chain] ?? '')) {
              runStarts.push(chain)
              while (chain < total && isComment(lines[chain] ?? '')) chain += 1
              chainEnd = chain
              let peek = chain
              while (peek < total && isBlank(lines[peek] ?? '')) peek += 1
              // Another comment run below the blank: the chain continues.
              if (peek < total && isComment(lines[peek] ?? '')) {
                chain = peek
                continue
              }
              chain = peek
              break
            }

            // The chain terminates at code, so every comment run in it was
            // floating above that code. Report each one: the reader meets all
            // of them before the code, so all of them are guilty.
            if (chain < total && isCode(lines[chain] ?? '')) {
              for (const start of runStarts) {
                context.report({
                  loc: {
                    start: { line: start + 1, column: 1 },
                    end: { line: start + 1, column: 1 },
                  },
                  messageId: 'floating',
                })
              }
            }
          }

          // Advance past the whole chain, not just this run: the runs below
          // the blank were already reported as part of it, and visiting them
          // again would report each one twice.
          index = chainEnd > runEnd ? chainEnd : runEnd
        }
      },
    }
  },
}

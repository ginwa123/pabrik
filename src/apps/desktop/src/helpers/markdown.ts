import { marked } from 'marked'

/**
 * Markdown rendering for surfaces that are NOT the chat transcript.
 *
 * `renderResponse` (renderResponse.ts) already covers the transcript: it
 * caches per message and special-cases `role`. Tool cards render outside
 * that path — an `ask_user` question, a plan body, a skill description —
 * and each of those had reached for a hand-rolled `{{ text }}`
 * interpolation, which shows the model its own `**bold**` and `` `code` ``
 * verbatim (the `ask_user` card was the reported case: a markdown-shaped
 * question rendered as one wall of `**Option 1 — …**`).
 *
 * Three functions, one per shape a card needs:
 *
 *   renderMarkdownHtml       — block markdown → `v-html` (the question).
 *   renderInlineMarkdownHtml — inline markdown → `v-html` (a one-line cell).
 *   stripMarkdownSyntax      — markdown → plain text (labels that MUST stay
 *                              text: a header pill, an option button's
 *                              label, a chip whose text is also the answer
 *                              value posted back to the model).
 *
 * The caller owns the styling: wrap the `v-html` host in `.markdown-content`
 * (global rules in `style.css`) and add any card-scoped overrides.
 *
 * Trust model (XSS): identical to the transcript's — `marked.parse` with no
 * sanitizer; the repo ships no DOMPurify. A question is authored by the
 * model, which may quote a file it read, so it is not strictly
 * self-XSS-only. Raw HTML in the source is therefore escaped before the
 * parse, which removes the `<img onerror=…>` / `<script>` class of problem
 * while leaving every legitimate markdown construct (emphasis, code, lists,
 * links, tables) intact.
 */

const escapeHtmlChars = (text: string): string =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

/**  * Block-level markdown → HTML, for `v-html`. `''` for blank input so callers can `v-if` the host on
 * the result. A parse throw falls back to an escaped `<p>` rather than throwing inside a render — a
 * broken question must not blank the card. */
export const renderMarkdownHtml = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    return marked.parse(escapeHtmlChars(source), { async: false }) as string
  } catch {
    return `<p>${escapeHtmlChars(source)}</p>`
  }
}

/**  * Inline-only markdown → HTML, for a `v-html` inside a text-flow element (one cell, one line, no
 * block wrapper). `**bold**`, `*em*`, `` `code` `` and `[text](url)` survive; paragraphs and lists
 * do not exist here. */
export const renderInlineMarkdownHtml = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    return marked.parseInline(escapeHtmlChars(source), { async: false }) as string
  } catch {
    return escapeHtmlChars(source)
  }
}

/**  * The subset of `marked`'s token shape this walk needs. `Tokens.Generic` is part of marked's
 * `Token` union, so a structural read is the honest way to flatten the whole tree without a cast at
 * every branch. */
interface FlatToken {
  type?: string
  text?: string
  tokens?: unknown[]
  items?: unknown[]
  header?: unknown[]
  rows?: unknown[][]
}

/** A table cell: `{ text, tokens, header, align }` — not itself a token. */
interface FlatCell {
  text?: string
  tokens?: unknown[]
}

/**  * A table's `header` / one of its `rows` → one space-joined line of words. Each element is a
 * `FlatCell`, so the recurse goes through `cell.tokens`; the `text` fallback covers a cell with no
 * inline tokens. */
const flattenCells = (cells: readonly unknown[]): string =>
  cells
    .map((cell) => {
      const c = (cell ?? {}) as FlatCell
      return Array.isArray(c.tokens) ? flattenTokens(c.tokens, '') : (c.text ?? '')
    })
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim()

/**
 * Walk the lexer output and keep only the words.
 *
 * Emphasis, links, headings, blockquotes, list items and tables all wrap
 * their text in a nested `tokens` / `items` array, so the walk recurses;
 * `Tokens.Generic` (an extension's custom token) falls through to the same
 * shape and therefore still contributes its text.
 *
 * `sep` is the string placed BETWEEN two adjacent tokens at THIS level.
 * It is `' '` at the top (the lexer's top level is a list of blocks, so two
 * blocks are two thoughts) and `''` one level down (a paragraph's children
 * are inline and already carry their own spacing). That distinction is the
 * whole point: joining a paragraph's children with spaces turns
 * `**staging**, but skip 087` into `staging , but skip 087`, which then
 * renders in the header pill and the answer chip.
 */
const flattenTokens = (tokens: readonly unknown[], sep: string): string => {
  const parts: string[] = []
  for (const entry of tokens) {
    const token = (entry ?? {}) as FlatToken
    switch (token.type) {
      case 'space':
      case 'html':
        // Whitespace-only and raw HTML contribute no words.
        break
      case 'code':
      case 'codespan':
        // Fenced / inline code keeps its words, without the backticks.
        parts.push(token.text ?? '')
        break
      case 'br':
        parts.push(' ')
        break
      case 'image':
        // Alt text is the human-readable part; the href is not a label.
        parts.push(token.text ?? '')
        break
      case 'table':
        parts.push(flattenCells(token.header ?? []))
        for (const row of token.rows ?? []) parts.push(flattenCells(row))
        break
      case 'list':
        parts.push(flattenTokens((token.items ?? []) as unknown[], ' '))
        break
      case 'text':
        parts.push(
          Array.isArray(token.tokens) ? flattenTokens(token.tokens, '') : (token.text ?? ''),
        )
        break
      default:
        if (Array.isArray(token.tokens)) {
          // paragraph, heading, strong, em, del, link, blockquote, list_item
          parts.push(flattenTokens(token.tokens, ''))
        } else if (Array.isArray(token.items)) {
          parts.push(flattenTokens(token.items, ' '))
        } else if (Array.isArray(token.header)) {
          parts.push(flattenCells(token.header))
        } else if (Array.isArray(token.rows)) {
          for (const row of token.rows) parts.push(flattenCells(row))
        } else if (typeof token.text === 'string') {
          parts.push(token.text)
        }
    }
  }
  return parts.join(sep)
}

/** Strip markdown syntax, keep the words. Blank → `''`.
 * Whitespace collapses to single spaces, so a multi-line question's first
 * 60 characters read as one line in a header pill. A real lexer pass (not
 * a regex) means nested emphasis inside a list item and tables come out
 * right instead of leaving stray `*` behind. */
export const stripMarkdownSyntax = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    // The lexer's top level is a list of BLOCKS, so they are joined with a
    // space; everything below that level is inline and joins tight.
    const text = flattenTokens(marked.lexer(source) as unknown[], ' ')
    return text.replace(/\s+/g, ' ').trim()
  } catch {
    return source.replace(/\s+/g, ' ').trim()
  }
}

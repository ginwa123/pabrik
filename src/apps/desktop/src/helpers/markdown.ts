import { marked } from 'marked'

/** Markdown rendering for surfaces that are NOT the chat transcript. `renderResponse`
 * (renderResponse.ts) already covers the transcript: it caches per message and special-cases
 * `role`. */
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

/** Walk the lexer output and keep only the words. */
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

/** Strip markdown syntax, keep the words. Blank → `''`. Whitespace collapses to single spaces, so a
 * multi-line question's first 60 characters read as one line in a header pill. */
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

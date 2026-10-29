import { Marked } from 'marked'

const escapeHtmlChars = (text: string): string =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

const parser = new Marked({ async: false })

parser.use({
  renderer: {
    html: (token) => escapeHtmlChars(token.text),
  },
})

export const renderMarkdownHtml = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    return parser.parse(source) as string
  } catch {
    return `<p>${escapeHtmlChars(source)}</p>`
  }
}

export const renderInlineMarkdownHtml = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    return parser.parseInline(source) as string
  } catch {
    return escapeHtmlChars(source)
  }
}

interface FlatToken {
  type?: string
  text?: string
  tokens?: unknown[]
  items?: unknown[]
  header?: unknown[]
  rows?: unknown[][]
}

interface FlatCell {
  text?: string
  tokens?: unknown[]
}

const flattenCells = (cells: readonly unknown[]): string =>
  cells
    .map((cell) => {
      const c = (cell ?? {}) as FlatCell
      return Array.isArray(c.tokens) ? flattenTokens(c.tokens, '') : (c.text ?? '')
    })
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim()

const flattenTokens = (tokens: readonly unknown[], sep: string): string => {
  const parts: string[] = []
  for (const entry of tokens) {
    const token = (entry ?? {}) as FlatToken
    switch (token.type) {
      case 'space':
      case 'html':
        break
      case 'code':
      case 'codespan':
        parts.push(token.text ?? '')
        break
      case 'br':
        parts.push(' ')
        break
      case 'image':
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

export const stripMarkdownSyntax = (source: string | null | undefined): string => {
  if (!source) return ''
  try {
    const text = flattenTokens(parser.lexer(source) as unknown[], ' ')
    return text.replace(/\s+/g, ' ').trim()
  } catch {
    return source.replace(/\s+/g, ' ').trim()
  }
}

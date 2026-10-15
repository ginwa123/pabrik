/**
 * helpers/markdown.ts — markdown → HTML / markdown → plain text.
 *
 * The `ask_user` card is the caller that motivated this: its `question` is
 * model-authored markdown ("Markdown allowed" in `ask_user.zig`'s schema)
 * and used to reach the DOM as literal `**bold**` text.
 *
 * These tests pin the three contracts the cards depend on:
 *   1. block markdown actually renders (bold / italic / code / list);
 *   2. raw HTML in the source cannot reach the DOM;
 *   3. `stripMarkdownSyntax` keeps the WORDS and drops only the syntax,
 *      because a stripped option label and the raw option string that gets
 *      POSTed back to the model must stay recognisably the same value.
 */
import { describe, it, expect } from 'vitest'
import { renderMarkdownHtml, renderInlineMarkdownHtml, stripMarkdownSyntax } from '../markdown'

describe('renderMarkdownHtml', () => {
  it('returns an empty string for blank input so callers can v-if the host', () => {
    expect(renderMarkdownHtml('')).toBe('')
    expect(renderMarkdownHtml(null)).toBe('')
    expect(renderMarkdownHtml(undefined)).toBe('')
  })

  it('renders the emphasis the ask_user question actually carries', () => {
    const html = renderMarkdownHtml(
      'Pick **Option 1 — Full 1:1**, or `linux/window.zig`, or *nothing*.',
    )
    expect(html).toContain('<strong>Option 1 — Full 1:1</strong>')
    expect(html).toContain('<code>linux/window.zig</code>')
    expect(html).toContain('<em>nothing</em>')
  })

  it('renders a multi-line markdown question as real blocks', () => {
    const html = renderMarkdownHtml('Which scope?\n\n- **A** — full mirror\n- `B` — names only')
    expect(html).toContain('<ul>')
    expect(html).toContain('<li>')
    expect(html).toContain('<strong>A</strong>')
    // …and not the raw fence/asterisk characters the card used to show.
    expect(html).not.toContain('**A**')
  })

  it('keeps a fenced code block readable', () => {
    const html = renderMarkdownHtml('Run this:\n\n```zig\nconst x = 1;\n```')
    expect(html).toContain('<pre>')
    expect(html).toContain('const x = 1;')
  })

  it('escapes raw HTML so the question cannot inject a node', () => {
    const html = renderMarkdownHtml('Deploy <img src=x onerror=alert(1)> & <script>bad()</script>?')
    expect(html).not.toContain('<img')
    expect(html).not.toContain('<script')
    // The text the human reads is unchanged.
    expect(html).toContain('&lt;img')
    expect(html).toContain('&amp;')
  })

  it('renders <>& in a plain question verbatim once the browser decodes it', () => {
    // Same assertion style as the AskUser card spec: the card's job is that
    // `<staging>` reads as `<staging>`, not as `<staging>`.
    const html = renderMarkdownHtml('Deploy <staging> & "prod"?')
    expect(html).toContain('&lt;staging&gt; &amp; &quot;prod&quot;?')
  })
})

describe('renderInlineMarkdownHtml', () => {
  it('renders inline emphasis without a block wrapper', () => {
    const html = renderInlineMarkdownHtml('**bold** and `code`')
    expect(html).toBe('<strong>bold</strong> and <code>code</code>')
  })

  it('leaves plain text as plain text', () => {
    expect(renderInlineMarkdownHtml('staging')).toBe('staging')
  })

  it('escapes raw HTML here too', () => {
    expect(renderInlineMarkdownHtml('<b>x</b>')).toBe('&lt;b&gt;x&lt;/b&gt;')
  })
})

describe('stripMarkdownSyntax', () => {
  it('is blank-safe', () => {
    expect(stripMarkdownSyntax('')).toBe('')
    expect(stripMarkdownSyntax(null)).toBe('')
    expect(stripMarkdownSyntax(undefined)).toBe('')
  })

  it('keeps the words of an emphasised option and drops the asterisks', () => {
    expect(stripMarkdownSyntax('**Option 1 — Full 1:1 (recommended)**')).toBe(
      'Option 1 — Full 1:1 (recommended)',
    )
  })

  it('drops backticks but keeps the code words', () => {
    expect(stripMarkdownSyntax('mirror `linux/window.zig` in `mac/render.zig`')).toBe(
      'mirror linux/window.zig in mac/render.zig',
    )
  })

  it('flattens a nested list question onto one line', () => {
    const stripped = stripMarkdownSyntax(
      'Which one?\n\n- **Option 1** — Full\n- Option 2 — names only\n',
    )
    expect(stripped).toBe('Which one? Option 1 — Full Option 2 — names only')
  })

  it('unwraps a link to its label, not its href', () => {
    expect(stripMarkdownSyntax('see [the plan](https://example.com/plan)')).toBe('see the plan')
  })

  it('does not inject a space where an inline token ends', () => {
    // Regression: joining a paragraph's inline children with ' ' turned `**staging**, but skip 087`
    // into `staging , but skip 087`, which then rendered in the ask_user header pill and the answer
    // chip. Blocks are space-joined; inline tokens concatenate.
    expect(stripMarkdownSyntax('**staging**, but skip `087`')).toBe('staging, but skip 087')
    expect(stripMarkdownSyntax('mirror `linux/window.zig` in `mac/render.zig`')).toBe(
      'mirror linux/window.zig in mac/render.zig',
    )
    expect(stripMarkdownSyntax('**bold**plain')).toBe('boldplain')
  })

  it('reduces a table to its cell words', () => {
    const stripped = stripMarkdownSyntax('| a | b |\n| - | - |\n| **1** | 2 |')
    expect(stripped).toContain('1')
    expect(stripped).toContain('2')
    expect(stripped).not.toContain('|')
  })

  it('leaves plain text untouched', () => {
    expect(stripMarkdownSyntax('Deploy target')).toBe('Deploy target')
  })
})

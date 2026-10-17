/** Static contract: one width token caps the transcript, and its presets live in CSS. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const src = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

// Built from parts: written out, this literal is a Tailwind candidate and the
// scanner would keep the now-dead utility in the shipped stylesheet.
const OLD_CAP = ['max-w', '4xl'].join('-')

describe('ChatView transcript width', () => {
  it('caps every transcript surface at the token, and none at the old 56rem cap', () => {
    expect(src).not.toContain(OLD_CAP)
    expect(src.match(/max-w-\[var\(--chat-content-max\)\]/g)).toHaveLength(4)
  })

  it('declares the token on .chat-column, with full as the default', () => {
    expect(src).toMatch(/\.chat-column \{[\s\S]{0,400}--chat-content-max: 100%/)
  })

  it('declares the narrowed presets as classes on the same column', () => {
    expect(src).toMatch(/\.chat-column\.chat-width-comfortable \{[\s\S]{0,80}896px/)
    expect(src).toMatch(/\.chat-column\.chat-width-wide \{[\s\S]{0,80}1400px/)
  })

  it('binds the preset class on the column that owns the token', () => {
    expect(src).toContain('class="relative flex flex-col h-full flex-1 min-w-0 chat-column"')
    expect(src).toContain(':class="chatWidthClass"')
    expect(src).toContain('const { presetClass: chatWidthClass } = useChatContentWidth()')
  })

  it('mirrors the pill-rail strip, so a full-bleed row keeps its text centred', () => {
    expect(src).toMatch(/has-pill-rail[\s\S]{0,700}padding-left: var\(--pill-rail-gutter/)
  })
})

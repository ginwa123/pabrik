/** Static contract: tool rows keep one stable full-column width whether collapsed or expanded. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { readChatViewSource } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewSource()
const headerSrc = readFileSync(
  resolve(__dirname, '../../tool_outputs/_shared/ToolCardHeader.vue'),
  'utf8',
)
const paramsSrc = readFileSync(
  resolve(__dirname, '../../tool_outputs/_shared/ToolParameters.vue'),
  'utf8',
)
const progressiveSrc = readFileSync(
  resolve(__dirname, '../../tool_outputs/ProgressiveTool.vue'),
  'utf8',
)

describe('ChatView tool-width consistency', () => {
  it('tool-group container fills the column (flex-1 w-full), not shrink-to-fit', () => {
    // The transcript row wrapper carries `min-w-0` statically and takes its width from the group's
    // role: a user turn is a right-aligned bubble, everything else — tool sequences included —
    // fills the column, so collapsed and expanded rows share the same width.
    expect(chatViewSrc).toMatch(/class="min-w-0"\s*\n\s*:class="/)
    expect(chatViewSrc).toMatch(/: 'flex-1 w-full max-w-full'/)
  })

  it('.tool-sequence and .tool-item are full-width with min-width 0', () => {
    expect(chatViewSrc).toMatch(/\.tool-sequence\)\s*\{[^}]*width:\s*100%/)
    expect(chatViewSrc).toMatch(/\.tool-item\)\s*\{[^}]*width:\s*100%/)
    expect(chatViewSrc).toMatch(/\.tool-item\)\s*\{[^}]*min-width:\s*0/)
  })

  it('.chat-tool-card is full-width with min-width 0 and clamps inner pre', () => {
    expect(chatViewSrc).toMatch(/\.chat-tool-card\)\s*\{[^}]*width:\s*100%/)
    expect(chatViewSrc).toMatch(/\.chat-tool-card\)\s*\{[^}]*min-width:\s*0/)
    expect(chatViewSrc).toMatch(/\.chat-tool-card pre\)\s*\{[^}]*max-width:\s*100%/)
    expect(chatViewSrc).toMatch(/\.chat-tool-card pre\)\s*\{[^}]*overflow-x:\s*auto/)
  })

  it('ToolCardHeader primary truncates inside fixed width (min-w-0)', () => {
    // flex-1 truncate without min-w-0 never ellipsizes in a flex row — a long
    // tool name/path forces the header wider instead.
    expect(headerSrc).toMatch(
      /flex-1[^"]*min-w-0[^"]*truncate|flex-1[^"]*truncate[^"]*min-w-0|min-w-0[^"]*flex-1[^"]*truncate/,
    )
  })

  it('ToolParameters pre scrolls inside instead of stretching the card', () => {
    expect(paramsSrc).toMatch(/max-w-full/)
    expect(paramsSrc).toMatch(/min-w-0/)
    expect(paramsSrc).toMatch(/overflow-x-auto/)
  })

  it('ProgressiveTool expanded pre blocks scroll inside instead of stretching', () => {
    expect(progressiveSrc).toMatch(/max-w-full/)
    expect(progressiveSrc).toMatch(/min-w-0/)
  })
})

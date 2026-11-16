/** Regression tests for the 2026-08-23 "auto-collapse on SSE" bug. */
import { describe, it, expect } from 'vitest'
import { readChatViewSource as readChatViewBundle } from './helpers/chatViewSource'

const readChatViewSource = async (): Promise<string> => readChatViewBundle()

const readPresentationSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const presentationPath = path.resolve(
    __dirname,
    '..',
    'components',
    'views',
    'chat_view',
    'useChatMessagePresentation.ts',
  )
  return fs.readFile(presentationPath, 'utf8')
}

describe('expandedToolIds — stable per-message keys (source contract)', () => {
  it('declares the expandedToolIds ref with a stability comment', async () => {
    const source = await readChatViewSource()
    // The ref MUST be a Set<string> (we key by string ids, not positions).
    expect(source).toMatch(/const expandedToolIds = ref<Set<string>>\(new Set\(\)\)/)
    // The comment MUST mention the auto-collapse fix so future maintainers understand why this isn't a positional key.
    expect(source).toMatch(/auto-collapse fix/)
  })

  it('toggleToolExpanded takes a single string key argument', async () => {
    const source = await readChatViewSource()
    // Old signature was `toggleToolExpanded(groupIndex: number, msgIndex: number)` — positional.
    expect(source).toMatch(/const toggleToolExpanded = \(msgId: string\) =>/)
    expect(source).not.toMatch(/toggleToolExpanded = \(groupIndex: number, msgIndex: number\)/)
  })

  it('declares a toolExpandKey helper that prefers msg.id over position', async () => {
    const source = await readPresentationSource()
    // The helper MUST exist and prioritise msg.id (stable), then tool_call_id (stable across the turn), then a positional fallback (last resort for legacy rows with …
    expect(source).toMatch(
      /const toolExpandKey = \(msg: Message, groupIndex: number, idx: number\): string =>/,
    )
    expect(source).toMatch(
      /return msg\.id \|\| msg\.tool_call_id \|\| `pos-\$\{groupIndex\}-\$\{idx\}`/,
    )
  })

  it('all usages of expandedToolIds route through toolExpandKey', async () => {
    const source = await readPresentationSource()
    // Find every read of `expandedToolIds`.
    const hasUsages = source.match(/expandedToolIds(?:\.value)?\.has\([^)]*\)/g) ?? []
    expect(hasUsages.length).toBeGreaterThan(0)
    for (const usage of hasUsages) {
      expect(usage).toMatch(/toolExpandKey\(msg, groupIndex, idx\)/)
      expect(usage).not.toMatch(/`\$\{groupIndex\}-\$\{idx\}`/)
    }
  })

  it('tool-group v-for keys by message id, not array index', async () => {
    const source = await readChatViewSource()
    // The tool group MUST v-for with a stable key.
    expect(source).toMatch(/v-for="\(card, idx\) in toolCardsFor\(group, groupIndex\)"/)
    const presentation = await readPresentationSource()
    expect(presentation).toMatch(/expandKey: toolExpandKey\(msg, groupIndex, idx\)/)
    const groupBlock = source.slice(
      source.indexOf('v-for="(card, idx) in toolCardsFor(group, groupIndex)"'),
      source.indexOf('v-for="(card, idx) in toolCardsFor(group, groupIndex)"') + 200,
    )
    expect(groupBlock).toContain(':key="card.expandKey"')
    expect(groupBlock).not.toContain(':key="idx"')
  })
})

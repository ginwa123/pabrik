/** Regression tests for the 2026-08-23 "auto-collapse on SSE" bug. Background: the chatview used
 * positional expand keys (`${groupIndex}-${idx}`) into the `messageGroups` computed. */
import { describe, it, expect } from 'vitest'

const readChatViewSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const chatviewPath = path.resolve(
    __dirname,
    '..',
    'components',
    'views',
    'ChatView.vue',
  )
  return fs.readFile(chatviewPath, 'utf8')
}

describe('expandedToolIds — stable per-message keys (source contract)', () => {
  it('declares the expandedToolIds ref with a stability comment', async () => {
    const source = await readChatViewSource()
    // The ref MUST be a Set<string> (we key by string ids, not positions).
    expect(source).toMatch(/const expandedToolIds = ref<Set<string>>\(new Set\(\)\)/)
    // The comment MUST mention the auto-collapse fix so future maintainers
    // understand why this isn't a positional key.
    expect(source).toMatch(/auto-collapse fix/)
  })

  it('toggleToolExpanded takes a single string key argument', async () => {
    const source = await readChatViewSource()
    // Old signature was `toggleToolExpanded(groupIndex: number, msgIndex: number)`
    // — positional. New signature is `toggleToolExpanded(msgId: string)` —
    // stable per-message.
    expect(source).toMatch(/const toggleToolExpanded = \(msgId: string\) =>/)
    expect(source).not.toMatch(/toggleToolExpanded = \(groupIndex: number, msgIndex: number\)/)
  })

  it('declares a toolExpandKey helper that prefers msg.id over position', async () => {
    const source = await readChatViewSource()
    // The helper MUST exist and prioritise msg.id (stable), then
    // tool_call_id (stable across the turn), then a positional
    // fallback (last resort for legacy rows with no id).
    expect(source).toMatch(/const toolExpandKey = \(msg: Message, groupIndex: number, idx: number\): string =>/)
    expect(source).toMatch(/return msg\.id \|\| msg\.tool_call_id \|\| `pos-\$\{groupIndex\}-\$\{idx\}`/)
  })

  it('all template usages of expandedToolIds route through toolExpandKey', async () => {
    const source = await readChatViewSource()
    // Find every line that reads `expandedToolIds.has(...)`. None of them may use the old
    // positional `${groupIndex}-${idx}` template literal — every read must route through the
    // helper.
    const hasUsages = source.match(/expandedToolIds\.has\([^)]*\)/g) ?? []
    expect(hasUsages.length).toBeGreaterThan(0)
    for (const usage of hasUsages) {
      expect(usage).toMatch(/toolExpandKey\(msg, groupIndex, idx\)/)
      expect(usage).not.toMatch(/`\$\{groupIndex\}-\$\{idx\}`/)
    }
  })

  it('tool-group v-for keys by message id, not array index', async () => {
    const source = await readChatViewSource()
    // The tool group MUST v-for with a stable key:
    //   `:key="msg.id || msg.tool_call_id || ..."`
    // It MUST NOT be just `:key="idx"`.
    expect(source).toMatch(
      /v-for="\(msg, idx\) in group\.messages"\s*\n\s*:key="msg\.id \|\| msg\.tool_call_id \|\| `t-\$\{groupIndex\}-\$\{idx\}`"/,
    )
    expect(source).not.toMatch(
      /v-for="\(msg, idx\) in group\.messages"\s*\n\s*:key="idx"/,
    )
  })
})
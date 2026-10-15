/** Regression tests for the 2026-08-23 "stray TOOLS pill" bug. Background: `groupToolNames` showed
 * a "tools" pill for any assistant group whose next group was not role='tool'. */
/** During live SSE there was a window where the assistant tool_calls row had arrived but the tool
 * result row had not — so the pill flashed even though a structured tool card would appear a frame
 * later. */
/** Worse, the pill could persist wrongly if the tool group got collapsed / dropped / merged by
 * `filteredMessages` or `hasBubbleContent`. */
/** Fix: walk the WHOLE transcript for matching tool_call_ids and suppress the pill when every tool
 * call is already represented by a structured card. Robust against ordering, merging, and live SSE
 * interleaving. */
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

describe('groupToolNames — pill suppression when tool already rendered (source contract)', () => {
  it('pre-collects rendered tool_call_ids from every tool group in the transcript', async () => {
    const source = await readChatViewSource()
    // The computed MUST walk every tool group and gather the set of tool_call_ids that have a
    // matching tool row. Without this, the pill flashes during the live-SSE window between the
    // assistant tool_calls row arriving and the tool result row arriving.
    expect(source).toMatch(/const renderedToolCallIds = new Set<string>\(\)/)
    expect(source).toMatch(/if \(g\.role !== 'tool'\) continue/)
    expect(source).toMatch(/if \(m\.tool_call_id\) renderedToolCallIds\.add\(m\.tool_call_id\)/)
  })

  it('suppresses the pill when EVERY tool_call has a matching tool row', async () => {
    const source = await readChatViewSource()
    // Look for the suppression block — `parsed.every((tc) => tool_call_id in renderedToolCallIds) →
    // return null`. This is the core fix: an assistant tool_calls row whose tools are already
    // represented by structured cards must NOT render a redundant "tools" pill.
    expect(source).toMatch(/const allRendered = parsed\.every\(/)
    expect(source).toMatch(/renderedToolCallIds\.has\(id\)/)
    expect(source).toMatch(/if \(allRendered\) return null/)
  })

  it('fallback "... " pill also checks for later tool groups', async () => {
    const source = await readChatViewSource()
    // When tool_calls_json is missing / unparseable but finish_reason='tool_calls', the pill
    // previously always rendered.

    // The fix scans for ANY later tool group in the transcript and suppresses the pill if one is
    // found — covering the common server-side case where the assistant row arrives first and the
    // tool result row arrives shortly after.
    expect(source).toMatch(/hasLaterTool = true/)
    expect(source).toMatch(/if \(hasLaterTool\) return null/)
  })

  it('returns null on the normal no-pill path (assistant text without tool_calls)', async () => {
    const source = await readChatViewSource()
    // The groupToolNames computed MUST still end with a `return null` branch (no pill) — a plain
    // assistant text turn must NOT render. We isolate the computed body via the unique
    // `renderedToolCallIds` anchor so future refactors don't accidentally regress the path.

    // Anchor on the unique identifier "renderedToolCallIds" that only exists in the fixed computed.
    // Walk forward from there to the next blank-line + comment boundary so the assertion is robust
    // against future whitespace changes.
    const anchorIdx = source.indexOf('const renderedToolCallIds = new Set<string>()')
    expect(anchorIdx).toBeGreaterThan(-1)
    // The end of the computed body is the next `})\n})` (map close,
    // then computed close) AFTER the anchor.
    const afterAnchor = source.slice(anchorIdx)
    const endIdx = afterAnchor.indexOf('})\n})')
    expect(endIdx).toBeGreaterThan(-1)
    const body = afterAnchor.slice(0, endIdx + '})\n})'.length)
    expect(body).toMatch(/return null/)
    // AND there must be a "fallback ..." pill branch (so the trailing
    // null is reached AFTER the fallback didn't trigger).
    expect(body).toContain("return '...'")
  })

  it('still renders the pill when NO tool row exists for the assistant turn', async () => {
    const source = await readChatViewSource()
    // Regression guard: the pill must still appear for genuine tool-only assistant turns (no
    // matching tool result in the transcript — e.g. aborted tool calls, server-side errors that
    // lost the tool row). The names.join(', ') branch must survive.
    expect(source).toMatch(/return names\.join\(', '\)/)
  })
})
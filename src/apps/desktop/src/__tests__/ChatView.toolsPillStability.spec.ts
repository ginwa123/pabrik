/** Regression tests for the 2026-08-23 "stray TOOLS pill" bug. Background: `groupToolNames` showed
 * a "tools" pill for any assistant group whose next group was not role='tool'. */
import { describe, it, expect } from 'vitest'

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

describe('groupToolNames — pill suppression when tool already rendered (source contract)', () => {
  it('pre-collects rendered tool_call_ids from every tool group in the transcript', async () => {
    const source = await readPresentationSource()
    // The computed MUST walk every tool group and gather the set of tool_call_ids that have a
    // matching tool row. Without this, the pill flashes during the live-SSE window between the
    // assistant tool_calls row arriving and the tool result row arriving.
    expect(source).toMatch(/const renderedToolCallIds = new Set<string>\(\)/)
    expect(source).toMatch(/if \(g\.role !== 'tool'\) continue/)
    expect(source).toMatch(/if \(m\.tool_call_id\) renderedToolCallIds\.add\(m\.tool_call_id\)/)
  })

  it('suppresses the pill when EVERY tool_call has a matching tool row', async () => {
    const source = await readPresentationSource()
    // Look for the suppression block — `parsed.every((tc) => tool_call_id in renderedToolCallIds) →
    // return null`. This is the core fix: an assistant tool_calls row whose tools are already
    // represented by structured cards must NOT render a redundant "tools" pill.
    expect(source).toMatch(/const allRendered = parsed\.every\(/)
    expect(source).toMatch(/renderedToolCallIds\.has\(id\)/)
    expect(source).toMatch(/if \(allRendered\) return null/)
  })

  it('fallback "... " pill also checks for later tool groups', async () => {
    const source = await readPresentationSource()
    // When tool_calls_json is missing / unparseable but finish_reason='tool_calls', the pill
    // previously always rendered.
    expect(source).toMatch(/hasLaterTool = true/)
    expect(source).toMatch(/if \(hasLaterTool\) return null/)
  })

  it('returns null on the normal no-pill path (assistant text without tool_calls)', async () => {
    const source = await readPresentationSource()
    // The groupToolNames computed MUST still end with a `return null` branch (no pill) — a plain
    // assistant text turn must NOT render. We isolate the computed body via the unique
    // `renderedToolCallIds` anchor so future refactors don't accidentally regress the path.
    const anchorIdx = source.indexOf('const renderedToolCallIds = new Set<string>()')
    expect(anchorIdx).toBeGreaterThan(-1)
    // The end of the computed body is the next map close followed by the computed
    // close AFTER the anchor, at whatever indentation the computed now lives at.
    const afterAnchor = source.slice(anchorIdx)
    const endMatch = /\}\)\n\s*\}\)/.exec(afterAnchor)
    expect(endMatch).not.toBeNull()
    const endIdx = endMatch!.index
    const body = afterAnchor.slice(0, endIdx + endMatch![0].length)
    expect(body).toMatch(/return null/)
    // AND there must be a "fallback ..." pill branch (so the trailing
    // null is reached AFTER the fallback didn't trigger).
    expect(body).toContain("return '...'")
  })

  it('still renders the pill when NO tool row exists for the assistant turn', async () => {
    const source = await readPresentationSource()
    // Regression guard: the pill must still appear for genuine tool-only assistant turns (no
    // matching tool result in the transcript — e.g. aborted tool calls, server-side errors that
    // lost the tool row). The names.join(', ') branch must survive.
    expect(source).toMatch(/return names\.join\(', '\)/)
  })
})

/** `toolPayloadPreview` — what the EXPANDED body of ChatView's generic tool
 * fallback shows for a tool with no registered output card.
 * It is the other half of the fix whose collapsed half is
 * `renderResponse`'s unregistered-tool pill: the payload moved out of the
 * one-line summary and into a collapsed-by-default body, so it has to be
 * readable there (pretty-printed) and bounded (an `add_element` row in the
 * live DB is 52 KB). */
import { describe, expect, it } from 'vitest'

import { toolPayloadPreview, TOOL_PAYLOAD_PREVIEW_MAX } from '../toolPayloadPreview'

const ENVELOPE = JSON.stringify({
  tool: 'set_pull_request',
  parameters: { pr_url: 'https://github.com/ginwa123/pabrik/pull/922' },
  success: true,
  data: {
    session_id: 'task_1791883461055_3',
    attached: true,
    url: 'https://github.com/ginwa123/pabrik/pull/922',
    number: '922',
  },
  error: null,
  v: 1,
})

describe('toolPayloadPreview', () => {
  it('pretty-prints the envelope data so it is readable on multiple lines', () => {
    const out = toolPayloadPreview(ENVELOPE)
    expect(out).toContain('"session_id": "task_1791883461055_3"')
    expect(out).toContain('"number": "922"')
    // Indented, not one long line.
    expect(out.split('\n').length).toBeGreaterThan(3)
    // The envelope chrome is dropped — `data` is the payload.
    expect(out).not.toContain('"v": 1')
  })

  it('shows the error sentence when the tool failed', () => {
    const failed = JSON.stringify({
      tool: 'list_secrets',
      parameters: {},
      success: false,
      data: null,
      error: 'workspace has no secrets store',
      v: 1,
    })
    expect(toolPayloadPreview(failed)).toBe('workspace has no secrets store')
  })

  it('passes a legacy non-JSON payload through verbatim', () => {
    const legacy = '<tool><name>add_element</name><data>hello</data></tool>'
    expect(toolPayloadPreview(legacy)).toBe(legacy)
  })

  it('caps a 52 KB legacy row and says how much was dropped', () => {
    const huge = `<tool><name>add_element</name><data>${'x'.repeat(60_000)}</data></tool>`
    const out = toolPayloadPreview(huge)
    expect(out.length).toBeLessThan(TOOL_PAYLOAD_PREVIEW_MAX + 100)
    expect(out).toContain('… truncated (')
    expect(out.startsWith('<tool><name>add_element</name>')).toBe(true)
  })

  it('honours an explicit cap', () => {
    const out = toolPayloadPreview('<tool><data>' + 'y'.repeat(500) + '</data></tool>', 100)
    expect(out.startsWith('<tool><data>')).toBe(true)
    expect(out.slice(0, 100)).toHaveLength(100)
    expect(out).not.toContain('y'.repeat(101))
    expect(out).toContain('truncated (')
  })

  it('returns an empty string for missing or blank content, never "null"', () => {
    expect(toolPayloadPreview('')).toBe('')
    expect(toolPayloadPreview('   \n ')).toBe('')
    expect(toolPayloadPreview(null)).toBe('')
    expect(toolPayloadPreview(undefined)).toBe('')
    expect(toolPayloadPreview({ not: 'a string' })).toBe('')
  })
})

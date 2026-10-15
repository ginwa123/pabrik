/**
 * Regression tests for the 2026-08-24 "stray TOOLS pill" wire-shape bug.
 *
 * Background (task_1787545088500_6, bug A): the backend SseEventLLMHistory
 * struct (src/ai_workflow/tui/agentic_loop/sse_on_event_send_llm_history.zig)
 * serializes `tool_calls_json` onto the wire — that's the assistant row's
 * serialized `tool_calls` array (e.g. `[{"id":"...","function":{"name":"bash"}}]`).
 * The frontend ChatView.vue groupToolNames computed (line ~1376) needs this
 * field to walk `parsed[i].id` and suppress the pill when every tool_call
 * has a matching tool row in the transcript.
 *
 * Without this field on the wire:
 *  1. The frontend SseEvent interface (api/index.ts ~1331) drops it — TS
 *     can't even prove it exists at compile time.
 *  2. The SSE full-handler push (ChatView.vue ~2300) never sets it on the
 *     pushed message, so groupToolNames falls into the `finish_reason ===
 *     'tool_calls'` heuristic and the pill flashes during the live-SSE
 *     window between assistant and tool rows.
 *
 * These tests are SOURCE-CONTRACT tests because the bug is at the wire
 * boundary — there is no runtime feedback until a real SSE round-trip
 * happens. Same pattern as ChatView.toolsPillStability.spec.ts.
 */
import { describe, it, expect } from 'vitest'

const readFile = async (relPath: string): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const fullPath = path.resolve(__dirname, '..', relPath)
  return fs.readFile(fullPath, 'utf8')
}

const readApiSource = () => readFile('api/index.ts')
const readChatViewSource = () => readFile('components/views/ChatView.vue')

describe('SseEvent interface — tool_calls_json field (source contract)', () => {
  it('declares tool_calls_json on the SseEvent interface', async () => {
    const source = await readApiSource()
    // The SseEvent interface MUST carry tool_calls_json so the SSE full-handler in ChatView.vue can
    // push it onto the message. Without this the field arrives as an untyped property and the Vue
    // template can't see it — pill suppression is bypassed.
    // Anchor on the interface declaration to make the assertion robust against surrounding field
    // additions.
    const ifaceStart = source.indexOf('export interface SseEvent {')
    expect(ifaceStart).toBeGreaterThan(-1)
    const ifaceEnd = source.indexOf('}', ifaceStart)
    expect(ifaceEnd).toBeGreaterThan(ifaceStart)
    const ifaceBody = source.slice(ifaceStart, ifaceEnd)
    expect(ifaceBody).toMatch(/^\s*tool_calls_json\?:\s*(string|any)/m)
  })
})

describe('ChatView SSE full-handler push — tool_calls_json wiring (source contract)', () => {
  it('sets tool_calls_json when pushing a full event onto messages[]', async () => {
    const source = await readChatViewSource()
    // Locate the messages.value.push({...}) inside the SSE full handler.
    // Anchor on the dedupe log line + the closing push, since the dedupe
    // block is the unique identifier of the SSE full-handler.
    const dedupeIdx = source.indexOf("duplicate full event skipped")
    expect(dedupeIdx).toBeGreaterThan(-1)
    const afterDedupe = source.slice(dedupeIdx)
    // Find the NEXT `messages.value.push({` after the dedupe.
    const pushIdx = afterDedupe.indexOf('messages.value.push({')
    expect(pushIdx).toBeGreaterThan(-1)
    // Find the close of that push block: the matching `})` before the
    // next standalone statement. We bound by 80 lines to keep this
    // resilient against future refactors.
    const pushStart = dedupeIdx + pushIdx
    const pushSlice = source.slice(pushStart, pushStart + 4000)
    const pushBodyEnd = pushSlice.indexOf('})')
    expect(pushBodyEnd).toBeGreaterThan(-1)
    const pushBody = pushSlice.slice(0, pushBodyEnd + 2)
    // The wire-shape fix MUST be present in the push body. Any property
    // name is fine; the source contract is "tool_calls_json is set from
    // the SSE event".
    expect(pushBody).toMatch(/tool_calls_json\s*:\s*event\.tool_calls_json/)
  })

  it('preserves the dedupe gate (regression guard for prior B1 fix)', async () => {
    // The B1 fix shipped in commit c50277d3 + frontend dedupe in
    // 3117496e: dedupe by role + tool_call_id + content. This test
    // guards against an accidental regression while wiring tool_calls_json.
    const source = await readChatViewSource()
    expect(source).toMatch(/duplicate full event skipped/)
    expect(source).toMatch(/m\.role !== role/)
    expect(source).toMatch(/\(m\.tool_call_id \?\? ''\) !== \(event\.tool_call_id \?\? ''\)/)
  })
})

/** Regression tests for the 2026-08-24 "stray TOOLS pill" wire-shape bug. */
import { describe, it, expect } from 'vitest'
import { readChatViewSource as readChatViewBundle } from './helpers/chatViewSource'

const readFile = async (relPath: string): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const fullPath = path.resolve(__dirname, '..', relPath)
  return fs.readFile(fullPath, 'utf8')
}

const readApiSource = () => readFile('api/sseEvents.ts')
const readChatViewSource = async (): Promise<string> => readChatViewBundle()

describe('SseEvent interface — tool_calls_json field (source contract)', () => {
  it('declares tool_calls_json on the SseEvent interface', async () => {
    const source = await readApiSource()
    // The SseEvent interface MUST carry tool_calls_json so the SSE full-handler in ChatView.vue can
    // push it onto the message. Without this the field arrives as an untyped property and the Vue
    // template can't see it — pill suppression is bypassed.
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
    // Locate the messages.value.push({...}) inside the SSE full handler. The dedupe gate is the
    // handler's unique identifier, so anchor on it (and on every push that follows it).
    const dedupeIdx = source.indexOf('const dup = messages.value.find((m) => {')
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
    expect(source).toMatch(/const dup = messages\.value\.find\(\(m\) => \{/)
    expect(source).toMatch(/if \(m\.role !== role\) return false/)
    expect(source).toMatch(/\(m\.tool_call_id \?\? ''\) !== \(event\.tool_call_id \?\? ''\)/)
    expect(source).toMatch(/if \(dup && role !== 'user'\) \{\s*\n\s*return/)
  })
})

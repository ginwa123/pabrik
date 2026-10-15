/** Regression lock: tool_calls_json wire shape (task_1787590621966_10)
 * Root cause of "msg.tool_calls_json?.trim is not a function":
 * the backend's on_event_sent.zig SSE emitter serialized the assistant
 * row's tool_calls as a JSON ARRAY while ChatView.vue:1390 calls
 * `.trim()` (string-only). Fixed backend-side (serialize once at emit)
 * AND hardened frontend-side with typeof guards. These source-contract
 * tests pin BOTH layers so neither can silently regress. */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const chatViewSrc = readFileSync(
  join(here, '../components/views/ChatView.vue'),
  'utf-8',
)
const peekSrc = readFileSync(
  join(here, '../composables/useSubAgentPeek.ts'),
  'utf-8',
)

describe('ChatView groupToolNames — tool_calls_json typeof guard', () => {
  it('guards .trim() behind a typeof string check (crash regression)', () => {
    // The old code: `if (msg.tool_calls_json?.trim())` — optional chaining
    // does NOT guard arrays, so an array-shaped value crashed the render.
    expect(chatViewSrc).not.toMatch(/msg\.tool_calls_json\?\.trim\(\)/)
    // The fixed code: explicit typeof check before .trim().
    expect(chatViewSrc).toMatch(
      /typeof msg\.tool_calls_json === 'string' && msg\.tool_calls_json\.trim\(\)/,
    )
  })

  it('guards parseSpawnSubAgentArgs call with a typeof check', () => {
    // findSubAgentArgsForToolGroup walks backwards through groups and
    // JSON.parses tool_calls_json — non-string values must be skipped.
    expect(chatViewSrc).toMatch(
      /typeof msg\.tool_calls_json !== 'string'\) continue/,
    )
  })
})

describe('useSubAgentPeek — legacy ev.tool_calls copy guard', () => {
  it('only copies STRING values into tool_calls_json (both sites)', () => {
    // The old code copied `ev.tool_calls ?? ...` unconditionally — the
    // legacy field was array-shaped on the old wire. Both copy sites
    // (update-existing + append-new) must now typeof-check first.
    const matches = peekSrc.match(/typeof \(ev as \{ tool_calls\?: unknown \}\)\.tool_calls === 'string'/g)
    expect(matches).not.toBeNull()
    expect(matches!.length).toBeGreaterThanOrEqual(2)
    // The unconditional legacy copies must be gone.
    expect(peekSrc).not.toMatch(/\(ev as \{ tool_calls\?: unknown \}\)\.tool_calls \?\? existing\.tool_calls_json/)
  })
})

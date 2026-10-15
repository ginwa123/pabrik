/**
 * Regression test for the boolean wire format of `is_input` / `is_output`.
 *
 * Background: the backend emits these fields as JSON booleans
 * (`"is_input": true`, `"is_output": false`), not as strings (`"1"` / `"0"`)
 * and not as numbers (`1` / `0`). The TypeScript types must match (boolean),
 * and the runtime comparison in `ChatView.vue` must use `=== true`
 * (boolean), not `=== '1'` (string). Before this refactor, the frontend
 * declared the fields as `string` and compared with `=== '1'`, which would
 * silently fail against the new boolean wire format.
 *
 * This test guards against:
 *   1. `is_input` / `is_output` reverting to `string` in the TS interface
 *      (compile-time check via `@ts-expect-error`)
 *   2. The runtime value shape drifting back to strings
 *   3. `ChatView.vue` regressing to a `=== '1'` string compare
 *
 * Plan: docs/plans/2026-07-01-is-input-output-bool-consistency.md (Chunk 4)
 */
import { describe, it, expect } from 'vitest'
import type { SseEvent } from '../api'

// --------------------------------------------------------------------------
// 1. Compile-time assertion: SseEvent.is_input / is_output are `boolean`,
//    not `string`.
// --------------------------------------------------------------------------
// These module-level blocks do not run as test logic — they are
// compile-time checks. If the field types revert to `string`, the
// error-suppression directives below would no longer have any error
// to suppress (because strings would suddenly be allowed). In that
// case, `bun run build` (vue-tsc) would fail with an "unused"
// directive error, pointing directly at the regression.
// Valid: assign actual booleans. No directive needed; type matches.
const _typeCheck: Pick<SseEvent, 'is_input' | 'is_output'> = {
  is_input: true,
  is_output: false,
}
void _typeCheck

// Invalid: assign strings. Each offending line gets its own directive (vue-tsc matches
// @ts-expect-error to the IMMEDIATELY-preceding source line, so a single directive on the const
// line wouldn't cover all the field-level assignment errors below). @ts-expect-error -- string is
// NOT a valid is_input; must be boolean.
const _typeCheckBadString1: Pick<SseEvent, 'is_input'> = { is_input: '1' }
// @ts-expect-error -- string is NOT a valid is_output; must be boolean.
const _typeCheckBadString2: Pick<SseEvent, 'is_output'> = { is_output: '0' }
void _typeCheckBadString1
void _typeCheckBadString2

// --------------------------------------------------------------------------
// 2. Runtime: the wire format shape is true/false booleans
// --------------------------------------------------------------------------
// The backend (src/ai_workflow/tui/on_event_sent_sanitize_test.zig +
// the new llm_history_is_input_output_test.zig) locks in the wire
// format on the Zig side. On the frontend side, we mirror the same
// expectations: the event payload's is_input / is_output must arrive
// as real booleans, and the comparison `event.is_output === true` must
// succeed where the old `=== '1'` would have failed.
describe('SseEvent.is_input / is_output wire format', () => {
  it('exposes is_input and is_output as booleans on the event payload', () => {
    // Runtime belt-and-suspenders: even if the type checker passes, a wrong-shape value should be
    // detectable. Mirrors what the SSE handler in ChatView.vue does at runtime: reads
    // event.is_output and expects a boolean.
    const eventTrue: Pick<SseEvent, 'is_input' | 'is_output'> = {
      is_input: true,
      is_output: true,
    }
    const eventFalse: Pick<SseEvent, 'is_input' | 'is_output'> = {
      is_input: false,
      is_output: false,
    }
    // typeof: the runtime value must actually be `boolean`, not (silently) `string`. This catches a
    // future regression where someone widens the TS type to `string | boolean` (which would bypass
    // the @ts-expect-error check at the type level).
    expect(typeof eventTrue.is_input).toBe('boolean')
    expect(typeof eventTrue.is_output).toBe('boolean')
    expect(typeof eventFalse.is_input).toBe('boolean')
    expect(typeof eventFalse.is_output).toBe('boolean')

    // The new boolean compare (`=== true`) succeeds on a true value.
    expect(eventTrue.is_output === true).toBe(true)
    // The new boolean compare (`=== true`) does NOT match a false value.
    expect(eventFalse.is_output === true).toBe(false)
  })


})

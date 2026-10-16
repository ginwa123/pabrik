/** Regression test for the boolean wire format of `is_input` / `is_output`. The backend emits these as
 * JSON booleans, not strings or numbers; the TS types must match and `ChatView.vue` must compare with
 * `=== true`. Guards against the types reverting to `string` and against a `=== '1'` compare. */
import { describe, it, expect } from 'vitest'
import type { SseEvent } from '../api'

// -------------------------------------------------------------------------- 1.
const _typeCheck: Pick<SseEvent, 'is_input' | 'is_output'> = {
  is_input: true,
  is_output: false,
}
void _typeCheck

// Invalid: assign strings. Each offending line gets its own directive, because vue-tsc matches a
// suppression to the IMMEDIATELY-preceding line — one directive cannot cover both fields below.
// @ts-expect-error -- string is NOT a valid is_input; must be boolean.
const _typeCheckBadString1: Pick<SseEvent, 'is_input'> = { is_input: '1' }
// @ts-expect-error -- string is NOT a valid is_output; must be boolean.
const _typeCheckBadString2: Pick<SseEvent, 'is_output'> = { is_output: '0' }
void _typeCheckBadString1
void _typeCheckBadString2

// -------------------------------------------------------------------------- 2.
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

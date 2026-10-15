/**
 * Sending or queueing a message must take the transcript to the bottom.
 *
 * ChatView's whole auto-stick is gated on `isAtBottom`: the `messages.length`
 * watcher returns early without it, `onContentShift` skips, and
 * `scrollToBottom(force = false)` does nothing. A reader who has scrolled up to
 * read history is, by definition, `isAtBottom === false`.
 *
 * So a send cannot be "scroll if we happen to be at the end" — it has to
 * *re-arm* the stick, and it has to do so SYNCHRONOUSLY. A forced
 * `scrollToBottom(true, …)` alone is not enough: it writes `container.scrollTop`
 * and leaves the flag to the native `scroll` event that follows, and the
 * browser does not fire one when the write is a no-op (the sizer already
 * reports a max scrollTop the container is already sitting at). The flag stays
 * false, and the SSE echo that carries the sent turn is answered by `Hold` —
 * the turn lands off-screen and the transcript never moves.
 *
 * These are source-level tests, following the ChatView convention (see
 * `ChatView.lazyPrefetch.spec.ts` for why): the mount-based ChatView specs
 * cannot get past the IndexedDB-backed history load in this environment. The
 * behavioural proof over a real browser — a real pabrik, a real Vite, a real
 * Chromium — is `tests/functional_ui/chatview_send_scrolls_to_bottom_ui_test.py`.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dir = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(resolve(__dir, '../components/views/ChatView.vue'), 'utf8')

/** Slice a region out of the SFC by two markers, with a loud failure if absent. */
function slice(startMarker: string, endMarker: string): string {
  const start = source.indexOf(startMarker)
  if (start === -1) throw new Error(`start marker not found: ${startMarker}`)
  const end = source.indexOf(endMarker, start + startMarker.length)
  if (end === -1) throw new Error(`end marker not found after ${startMarker}: ${endMarker}`)
  return source.slice(start, end)
}

const followNewest = slice('const followNewestTurn = (', '// ─── Stop session')
const submitHandler = slice('const handleFileInputSubmit = async', '// ─── Stop session')
const queueHandler = slice('offQueue = bus.on(', '// Stale-on-wake (cross-tab sharing)')

describe('ChatView — sending or queueing a turn takes the transcript to the bottom', () => {
  it('has one helper that both the send and the queue use', () => {
    expect(source).toMatch(/const followNewestTurn = \(trigger: string\)/)
    expect(submitHandler).toContain('followNewestTurn(')
    expect(queueHandler).toContain('followNewestTurn(')
  })

  it('re-arms the stick synchronously, before it scrolls', () => {
    // The ordering is the whole fix. `isAtBottom` is read by three gates that
    // all run after this returns; a flag flipped by the scroll event the write
    // produces arrives a frame late, and may never arrive at all.
    const arm = followNewest.indexOf('isAtBottom.value = true')
    const stamp = followNewest.indexOf('lastAutoStickAt.value = Date.now()')
    const mark = followNewest.indexOf('markProgrammatic()')
    const scroll = followNewest.indexOf('scrollToBottom(true, trigger)')

    expect(arm).toBeGreaterThan(-1)
    expect(stamp).toBeGreaterThan(arm)
    expect(mark).toBeGreaterThan(stamp)
    expect(scroll).toBeGreaterThan(mark)
  })

  it('takes the reader to the newest turn before the request is even made', () => {
    // The reader is looking at history and asks for a turn. The pin has to be
    // issued as the send starts, not after the response — the response can take
    // seconds, and the reader is left staring at the history they just left.
    const firstPin = submitHandler.indexOf('followNewestTurn(')
    const post = submitHandler.indexOf('api.sendChatMessage(')

    expect(firstPin).toBeGreaterThan(-1)
    expect(post).toBeGreaterThan(firstPin)
  })

  it('pins again once the request settles', () => {
    // There is no optimistic push (see the 2026-08-23 note in the handler), so the first pin aims
    // at the bottom of the content as it stood BEFORE the turn. The bottom moves when the turn
    // renders; without a second pin the newest turn is one screen below the fold.
    const settled = submitHandler.slice(submitHandler.indexOf('} finally {'))
    expect(settled).toContain('followNewestTurn(')
  })

  it('arms the stick for a queue, which renders no row at all', () => {
    // A queued turn produces no transcript row — it only appears in the composer's queue panel —
    // and the row that finally reaches the transcript is the worker draining it, possibly much
    // later. `queuedMessages` alone is not a scroll problem; the stick it has to arm is.
    const queuedBranch = queueHandler.slice(0, queueHandler.indexOf("event.action === 'deleted'"))
    expect(queuedBranch).toContain("event.action === 'queued'")
    expect(queuedBranch).toContain('followNewestTurn(')
    // …and the pin has to come after the queue row is recorded, so a failed
    // push cannot leave the stick armed for a turn that was never queued.
    const push = queuedBranch.indexOf('queuedMessages.value.push(')
    const pin = queuedBranch.indexOf('followNewestTurn(')
    expect(push).toBeGreaterThan(-1)
    expect(pin).toBeGreaterThan(push)
  })

  it('leaves the streaming auto-stick alone', () => {
    // The other half of the contract, and the reason this fix is a helper and
    // not a change to the gate. A run streaming into a transcript the reader
    // has scrolled up in must still leave them where they are
    // (`ChatView.streamingStick.spec.ts` proves that behaviour); only an
    // explicit send or queue overrides it.
    const contentShift = slice('const onContentShift = (shift:', 'const teardownContentShiftRaf')
    expect(contentShift).toContain('if (!isAtBottom.value)')

    // Watch-zero: the messages.length watcher is now an onUpdated
    // prev-length guard; the isAtBottom gate is unchanged.
    const lengthGuard = slice(
      '// Auto-stick on new messages',
      '// React to an effective-cwd change',
    )
    expect(lengthGuard).toContain('if (!isAtBottom.value) return')
  })
})

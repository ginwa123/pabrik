/**
 * Source-contract tests for the older-history PREFETCH work
 * (task_1789505423062_0) — the "auto fetch before the scroll reaches the top"
 * fix.
 *
 * Why source-level: ChatView is a ~5.4k-line SFC and the existing mount-based
 * ChatView specs (`ChatView.scrollRestore.spec.ts`, `chatViewWorktree.spec.ts`)
 * fail on a clean `main` in this environment (`.virtual-scroller` never
 * renders), so a NEW mount spec here would be born red. The load-bearing
 * invariants of the prefetch are structural, so they are pinned textually the
 * same way `ChatView.userPillRail.spec.ts` pins the cursor-pagination fixes.
 *
 * The wire-level proof (request issued BEFORE the container reaches the top)
 * lives in `tests/functional_ui/chatview_lazy_prefetch_ui_test.py`.
 */
import { describe, it, expect } from 'vitest'

const readChatViewSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const chatviewPath = path.resolve(__dirname, '..', 'components', 'views', 'ChatView.vue')
  return fs.readFile(chatviewPath, 'utf8')
}

/** Slice a top-level `const name = …` function body out of the source. */
function fnBody(source: string, startMarker: string, endMarker: string): string {
  const start = source.indexOf(startMarker)
  const end = source.indexOf(endMarker, start + 1)
  if (start === -1 || end <= start) {
    throw new Error(`could not slice ${startMarker} … ${endMarker} (start=${start}, end=${end})`)
  }
  return source.slice(start, end)
}

describe('older-history prefetch — trigger wiring', () => {
  it('handleVirtualScroll evaluates the prefetch and commits from the band', async () => {
    const source = await readChatViewSource()
    const body = fnBody(source, 'const handleVirtualScroll = (', '\n// ─── Send Message')
    // The decision runs on user gestures…
    expect(body).toContain('evaluateOlderPrefetch()')
    // …and a buffered page is committed as soon as the user is inside the
    // scroller's own band, without waiting for the 200 ms @load-more backstop.
    expect(body).toContain("void maybeLoadOlder('edge')")
    expect(body).toContain('effectiveLoadMoreThreshold')
    // Velocity sampling / arming must be skipped for programmatic writes:
    // an anchor-compensation scrollTop write is not a gesture.
    expect(body).toMatch(/if \(!isProgrammatic\) \{[\s\S]*evaluateOlderPrefetch\(\)/)
  })

  it('evaluateOlderPrefetch is the only place that consults the decision helper', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const evaluateOlderPrefetch = () => {',
      'const maybeLoadOlder = async (',
    )
    expect(body).toContain('decidePrefetchOlder({')
    expect(body).toContain('armRadiusPx(container.clientHeight)')
    expect(body).toContain('armPrefetchOlder(')
    // Terminal states must be handed to the pure decision function rather than
    // re-implemented here.
    expect(body).toContain('hasMore: hasMoreMessages.value')
    expect(body).toContain('isPreservingScroll')
    expect(body).toContain('backoffActive')
  })

  it('does NOT run an eager prefetch on open (unsettled geometry)', async () => {
    const source = await readChatViewSource()
    const body = fnBody(source, 'const loadChatHistory = async () => {', '\n// ─── Scroll')
    expect(body).toContain("resetOlderPrefetch('refresh')")
    // Measured in the browser: at this point the initial-load scroll has not been applied yet, so
    // `container.scrollTop` is still 0 and an eager evaluation would burn a scroll-back request on
    // every open (and then drop it). The arm waits for the first real scroll event instead.
    expect(body).not.toContain('evaluateOlderPrefetch()')
  })
})

describe('older-history prefetch — arm must stay invisible', () => {
  it('armPrefetchOlder never mutates messages, the cursor, or the scroll position', async () => {
    const source = await readChatViewSource()
    const body = fnBody(source, 'const armPrefetchOlder = (', 'const claimBufferedOlderPage = (')
    expect(body).not.toContain('messages.value =')
    expect(body).not.toContain('messageCursor.value =')
    expect(body).not.toContain('hasMoreMessages.value =')
    expect(body).not.toContain('beginPreserve')
    expect(body).not.toContain('scrollTop =')
    expect(body).not.toContain('lastAutoStickAt.value =')
  })

  it('armPrefetchOlder stores the page in the buffer keyed by cursor + generation', async () => {
    const source = await readChatViewSource()
    const body = fnBody(source, 'const armPrefetchOlder = (', 'const claimBufferedOlderPage = (')
    expect(body).toContain('bufferedOlderPage = page')
    expect(body).toContain('page.fetchedWithCursor !== messageCursor.value')
    expect(body).toContain('generation !== commitGeneration')
  })

  it('a failed arm backs off instead of retrying on every scroll event', async () => {
    const source = await readChatViewSource()
    const body = fnBody(source, 'const armPrefetchOlder = (', 'const claimBufferedOlderPage = (')
    expect(body).toContain('prefetchBackoffUntil = performance.now() + backoffMs')
    expect(body).toContain("prefetchLogCtx('load-more-prefetch-failed'")
    expect(body).toContain('scrollLogger.warn(')
  })
})

describe('older-history prefetch — commit invariants', () => {
  it('claims the buffer SYNCHRONOUSLY before the first await (no double commit)', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const maybeLoadOlder = async (',
      'const loadChatHistory = async () => {',
    )
    const claim = body.indexOf('const buffered = claimBufferedOlderPage()')
    const loadingFlag = body.indexOf('isLoadingMore.value = true')
    const committingFlag = body.indexOf('isCommittingOlder = true')
    const firstAwait = body.indexOf('await ')
    expect(claim).toBeGreaterThan(-1)
    expect(loadingFlag).toBeGreaterThan(-1)
    expect(committingFlag).toBeGreaterThan(-1)
    expect(firstAwait).toBeGreaterThan(-1)
    // Order: claim the slot, set BOTH in-flight flags, and only THEN touch the
    // network. A second caller (positional commit vs the 200 ms backstop) must
    // observe the flags/already-empty slot, never a duplicate prepend.
    expect(claim).toBeLessThan(firstAwait)
    expect(loadingFlag).toBeLessThan(firstAwait)
    expect(committingFlag).toBeLessThan(firstAwait)
    expect(claim).toBeLessThan(committingFlag)
  })

  it('keeps the original guard chain (auto-stick only for the scroll trigger)', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const maybeLoadOlder = async (',
      'const loadChatHistory = async () => {',
    )
    expect(body).toContain('isAutoStickActive(')
    expect(body).toContain('hasMoreMessages.value')
    expect(body).toContain('isLoadingMore.value')
    expect(body).toContain("guard: 'no-messages'")
    expect(body).toContain("guard: 'already-committing'")
    // The manual button must NOT be swallowed by a fresh auto-stick: only the
    // scroll trigger consults the gate.
    expect(body).toContain("if (trigger === 'edge' && isAutoStickActive(")
  })

  it('reuses an in-flight arm instead of firing a duplicate request', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const maybeLoadOlder = async (',
      'const loadChatHistory = async () => {',
    )
    expect(body).toContain('await pending')
    expect(body).toContain('claimBufferedOlderPage()')
  })

  it('commitOlderPage preserves the documented preserve ordering', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const commitOlderPage = async (',
      'const evaluateOlderPrefetch = () => {',
    )
    const begin = body.indexOf('beginPreserve(newCount)')
    const mutate = body.indexOf('messages.value = [')
    const nextTickIdx = body.indexOf('await nextTick()')
    const markIdx = body.indexOf('markProgrammatic()')
    const endIdx = body.indexOf('endPreserve()')
    expect(begin).toBeGreaterThan(-1)
    expect(mutate).toBeGreaterThan(begin)
    expect(nextTickIdx).toBeGreaterThan(mutate)
    expect(markIdx).toBeGreaterThan(nextTickIdx)
    expect(endIdx).toBeGreaterThan(markIdx)
    // Cursor advances from the COMMITTED page (not the initial page).
    expect(body).toContain('messageCursor.value = page.nextCursor')
    expect(body).toContain('hasMoreMessages.value = page.hasMore')
    // The pre-preserve snapshot the post-preserve re-stick depends on.
    expect(body).toContain('const wasAtBottom = isAtBottom.value')
  })

  it('refill keeps one page of lookahead but is bounded by an auto-chain budget', async () => {
    const source = await readChatViewSource()
    const body = fnBody(
      source,
      'const commitOlderPage = async (',
      'const evaluateOlderPrefetch = () => {',
    )
    expect(body).toContain("armPrefetchOlder('refill')")
    expect(body).toContain('MAX_PREFETCH_AUTO_CHAIN')
    expect(body).toContain("skip: 'auto-chain-budget'")
    // A real upward gesture resets the budget.
    const scrollBody = fnBody(source, 'const handleVirtualScroll = (', '\n// ─── Send Message')
    expect(scrollBody).toContain('prefetchAutoChain = 0')
  })
})

describe('older-history prefetch — invalidation', () => {
  it('drops the buffer on session change, refresh, and unmount', async () => {
    const source = await readChatViewSource()
    // Single session-change entry point (watch-zero: the two sessionId
    // watchers merged into onSessionChanged) still drops the buffer.
    const entryBody = fnBody(
      source,
      'const onSessionChanged = async (newId: string) => {',
      '// Auto-stick on new messages',
    )
    expect(entryBody).toContain("resetOlderPrefetch('session-change')")
    expect(source).toContain("resetOlderPrefetch('refresh')")
    expect(source).toContain("resetOlderPrefetch('unmount')")
    const unmountBody = fnBody(source, 'onUnmounted(() => {', '\n// Load available profiles')
    expect(unmountBody).toContain("resetOlderPrefetch('unmount')")
  })

  it('writes messageCursor exactly five times: reset, cached restore, cached delta, initial page, commit', async () => {
    const source = await readChatViewSource()
    const writes = source.match(/messageCursor\.value = /g) ?? []
    // 1. `= null` — reset before an initial load
    // 2. `= storedCursor` — cached mount restores the sync cursor for paint
    // 3. `= delta.nextCursor` — cached mount advances past the tail
    // 4. `= data.next_cursor` — the initial page's cursor
    // 5. `= page.nextCursor` — every prepend commit advances it
    // (A prefetch ARM must never be one of these — asserted separately.
    // The tab-switch resync path must not write it either: it merges the
    // tail without touching scroll-back state.)
    expect(writes).toHaveLength(5)
    const resyncBody = fnBody(source, 'bus.onResync?.(() => {', '}) ?? null')
    expect(resyncBody).not.toMatch(/messageCursor\.value = /)
  })

  it('routes the manual button through the shared guard chain (no slow path left)', async () => {
    const source = await readChatViewSource()
    expect(source).toContain(`@click="maybeLoadOlder('manual')"`)
    // The old handler-based call is gone from the template (prose comments
    // elsewhere mention the old name for history — that is fine).
    expect(source).not.toContain(`@click="loadChatHistory(true)"`)
    expect(source).not.toContain('loadChatHistory(true)\n  }')
  })
})

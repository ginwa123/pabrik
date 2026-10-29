/** Source-contract tests for the 2026-09-09 chatview user-pill work: cursor-pagination fixes +
 * pill-rail wiring in ChatView.vue. */
import { describe, it, expect } from 'vitest'
import { readChatViewSource as readChatViewBundle } from './helpers/chatViewSource'

const readChatViewSource = async (): Promise<string> => readChatViewBundle()

describe('pagination — cursor advances on loadMore', () => {
  it('advances messageCursor + hasMoreMessages on the initial load AND on every prepend', async () => {
    const source = await readChatViewSource()
    // Initial load: cursor + exhaustion flag come straight from the REST page.
    expect(source.match(/messageCursor\.value = data\.next_cursor/g) ?? []).toHaveLength(1)
    expect(source.match(/hasMoreMessages\.value = data\.has_more/g) ?? []).toHaveLength(1)
    // Every prepend (scroll-back, buffered prefetch, manual button) is routed through
    // `commitOlderPage`, which advances the cursor from the COMMITTED page. Without this the 2nd+
    // page re-sends the same cursor and re-prepends the same messages forever.
    const commitBody = source.slice(
      source.indexOf('const commitOlderPage = async ('),
      source.indexOf('const evaluateOlderPrefetch = '),
    )
    expect(commitBody.length).toBeGreaterThan(0)
    expect(commitBody).toContain('messageCursor.value = page.nextCursor')
    expect(commitBody).toContain('hasMoreMessages.value = page.hasMore')
  })

  it('dedupes prepended pages by id', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/new Set\(messages\.value\.map\(\(m\) => m\.id\)\)/)
    expect(source).toMatch(/\.filter\(\(m\) => !seenIds\.has\(m\.id\)\)/)
  })

  it('uses a full page size of 1000', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/const PAGE_SIZE = 1000\b/)
    expect(source).not.toMatch(/const PAGE_SIZE = 500\b/)
    expect(source).not.toMatch(/const PAGE_SIZE = 100\b/)
  })
})

describe('user-pill rail wiring', () => {
  it('imports and renders UserPillRail with pills + active index + jump handler', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/import UserPillRail.*from '\.\.\/chat\/UserPillRail\.vue'/)
    expect(source).toMatch(/<UserPillRail/)
    expect(source).toMatch(/v-if="userPills\.length >= 2"/)
    expect(source).toMatch(/:active-group-index="activePillGroupIndex"/)
    expect(source).toMatch(/@jump="jumpToUserGroup"/)
  })

  it('userPills covers user groups only and skips compaction envelopes', async () => {
    const source = await readChatViewSource()
    const block = source.match(/const userPills = computed\(\(\): UserPill\[\] => \{[\s\S]*?\n\}\)/)
    expect(block).not.toBeNull()
    expect(block![0]).toContain("g.role !== 'user'")
    expect(block![0]).toContain('isCompactionMessage')
    expect(block![0]).toContain('groupKey(g)')
  })

  it('group root carries a stable data-group-key for the flash query', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/:data-group-key="groupKey\(group\)"/)
  })

  it('jump marks programmatic, scrolls to the resolved item, and flashes', async () => {
    const source = await readChatViewSource()
    const fn = source.match(/const jumpToUserGroup = [\s\S]*?\n\}/)
    expect(fn).not.toBeNull()
    expect(fn![0]).toContain('scrollLogger.markProgrammatic()')
    expect(fn![0]).toContain('scrollToItem(target')
    expect(fn![0]).toContain('pill-jump-flash')
    // Index resolved by stable key at click time (SSE may shift positions).
    expect(fn![0]).toContain('findIndex((g) => groupKey(g) === key)')
  })
})

describe('pill-rail gutter — the rail must not overlap the transcript', () => {
  it('the wrapper carries has-pill-rail on the SAME condition as the rail', async () => {
    // The gutter must exist exactly when the rail does. Two separate conditions would drift: a rail
    // with no gutter paints over the messages, a gutter with no rail is dead space in a
    // 1-user-group chat. Pin the binding to the rail's own `v-if` expression.
    const source = await readChatViewSource()
    const wrapper = source.match(
      /class="relative flex-1 min-h-0 flex flex-col messages-scroll-hide-native"\s*\n\s*:class="\{[^}]*\}"/,
    )
    expect(wrapper).not.toBeNull()
    expect(wrapper![0]).toContain("'has-pill-rail': userPills.length >= 2")
  })

  it('the gutter is declared as a custom property on the wrapper', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(
      /\.messages-scroll-hide-native\.has-pill-rail\s*\{\s*--pill-rail-gutter:/,
    )
  })

  it('the gutter is wide enough to clear the rail footprint', async () => {
    // The rail sits at `right: 18px` with 4px padding and 24px pills, so its footprint reaches 46px
    // in from the wrapper's right edge. A narrower gutter would leave the pills still overlapping
    // the text. 48px also covers the pill's `scaleX(1.25)` hover growth (24 → 30px).
    const source = await readChatViewSource()
    const m = source.match(/--pill-rail-gutter:\s*(\d+)px/)
    expect(m).not.toBeNull()
    expect(Number(m![1])).toBeGreaterThanOrEqual(46)
  })

  it('the gutter is applied as padding-right on the transcript rows', async () => {
    // `padding-right`, NOT a margin or a width on the scroller: VirtualScroller's `measureItems()`
    // reads `el.offsetHeight`, so a horizontal padding is invisible to the height model.
    const source = await readChatViewSource()
    const rule = source.match(
      /\.messages-scroll-hide-native\.has-pill-rail :deep\(\[data-group-key\]\),[\s\S]*?\}/,
    )
    expect(rule).not.toBeNull()
    expect(rule![0]).toContain('padding-right: var(--pill-rail-gutter')
    expect(rule![0]).not.toContain('padding-bottom')
  })

  it('the agent-error band takes the same gutter', async () => {
    // It is a sibling of the VirtualScroller, outside the height model,
    // so it needs the padding in its own right — otherwise the strip
    // breaks across that band and the pills overlap it.
    const source = await readChatViewSource()
    expect(source).toMatch(/\.messages-scroll-hide-native\.has-pill-rail \.agent-error-list\s*\{/)
  })
})

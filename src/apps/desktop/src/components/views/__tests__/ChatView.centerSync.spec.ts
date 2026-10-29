/**  * Phase 3 scroll-spy + URL sync (3.3) and click-to-scroll (3.4, ChatView side): the most-visible
 * stacked section drives currentPath, which syncs to ?diff= via router.replace (never push); the
 * Back button clears the selection and deletes the param. */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { scrollToSectionElement, centerDiffSectionId } from '../chat_right_sidebar/parseUnifiedDiff'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()

describe('ChatView scroll-spy + URL sync', () => {
  it('reads the route (useRoute) beside useRouter', () => {
    expect(chatViewSrc).toMatch(/import \{ useRouter, useRoute \} from 'vue-router'/)
    expect(chatViewSrc).toMatch(/const route = useRoute\(\)/)
  })

  it('spy observes sections in the center scroll container with the active band', () => {
    expect(chatViewSrc).toMatch(/function startCenterSpy\(\)/)
    expect(chatViewSrc).toMatch(/rootMargin: '-40% 0px -55%'/)
    expect(chatViewSrc).toMatch(/centerDiffScrollRef\.value/)
    expect(chatViewSrc).toMatch(/dataset\.path/)
    expect(chatViewSrc).toMatch(/stopCenterSpy\(\)/)
  })

  it('syncs currentPath to ?diff= with replace (not push), back deletes it', () => {
    expect(chatViewSrc).toMatch(/function syncDiffParam\(path: string \| null\)/)
    expect(chatViewSrc).toMatch(/router\.replace\(\{ path: route\.path, query \}\)/)
    expect(chatViewSrc).toMatch(/delete query\.diff/)
    expect(chatViewSrc).toMatch(/watch\(currentPath/)
    expect(chatViewSrc).toMatch(/syncDiffParam\(null\)/)
  })
})

describe('scrollToSectionElement', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('scrolls the addressed section into view at block start', () => {
    const scrollIntoView = vi.fn()
    const getSpy = vi
      .spyOn(document, 'getElementById')
      .mockReturnValue({ scrollIntoView } as unknown as HTMLElement)
    expect(scrollToSectionElement('a/b.txt')).toBe(true)
    expect(getSpy).toHaveBeenCalledWith(centerDiffSectionId('a/b.txt'))
    expect(scrollIntoView).toHaveBeenCalledWith({ block: 'start' })
  })

  it('returns false when no section is mounted (no throw)', () => {
    vi.spyOn(document, 'getElementById').mockReturnValue(null)
    expect(scrollToSectionElement('missing.txt')).toBe(false)
  })
})

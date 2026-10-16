/** Phase 3 stacked center diff (3.2): ChatView renders ALL changed files stacked vertically — one
 * lazily-mounted CenterDiffSection per file — instead of a single SidebarDiffView. */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { shallowMount, flushPromises } from '@vue/test-utils'
import { nextTick } from 'vue'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import CenterDiffSection from '../chat_right_sidebar/CenterDiffSection.vue'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'
import {
  centerDiffSectionId,
  encodePathParam,
  decodePathParam,
} from '../chat_right_sidebar/parseUnifiedDiff'

const chatViewSrc = readFileSync(resolve(__dirname, '../ChatView.vue'), 'utf8')

describe('centerDiffSectionId', () => {
  it('is center-diff- + base64url without padding', () => {
    expect(centerDiffSectionId('foo.txt')).toBe(`center-diff-${encodePathParam('foo.txt')}`)
    expect(encodePathParam('foo.txt')).not.toMatch(/[+/=]/)
    expect(encodePathParam('a/b+c/d.txt')).not.toMatch(/[+/=]/)
  })

  it('round-trips listed paths and rejects unknown params', () => {
    const listed = ['foo.txt', 'a/b+c/d.txt']
    for (const p of listed) expect(decodePathParam(encodePathParam(p), listed)).toBe(p)
    expect(decodePathParam('!!!not-a-path!!!', listed)).toBeNull()
    expect(decodePathParam(encodePathParam('elsewhere.txt'), listed)).toBeNull()
  })
})

describe('CenterDiffSection lazy mount', () => {
  const observers: IntersectionObserverCallback[] = []
  const observeMock = vi.fn()
  const disconnectMock = vi.fn()

  const sectionProps = {
    sectionId: 'center-diff-Zm9vLnR4dA',
    path: 'foo.txt',
    lines: [{ type: 'add' as const, content: 'new', newLineNum: 1, lineIndex: 0 }],
    added: 1,
    removed: 0,
    staged: false,
    error: null,
    cwd: '/repo',
  }

  afterEach(() => {
    vi.unstubAllGlobals()
    observers.length = 0
    vi.clearAllMocks()
  })

  it('renders a placeholder until the section nears the viewport', async () => {
    vi.stubGlobal(
      'IntersectionObserver',
      class {
        constructor(cb: IntersectionObserverCallback) {
          observers.push(cb)
        }
        observe = observeMock
        unobserve = vi.fn()
        disconnect = disconnectMock
      },
    )
    const wrapper = shallowMount(CenterDiffSection, { props: sectionProps })
    await flushPromises()
    // Shell (id anchor + sizing) renders immediately; heavy diff waits.
    const section = wrapper.get('[data-testid="center-diff-section"]')
    expect(section.attributes('id')).toBe('center-diff-Zm9vLnR4dA')
    expect(section.attributes('style')).toContain('content-visibility')
    expect(wrapper.find('[data-testid="center-diff-placeholder"]').exists()).toBe(true)
    expect(wrapper.findComponent(SidebarDiffView).exists()).toBe(false)
    expect(observeMock).toHaveBeenCalledTimes(1)

    // Section nears viewport -> mount the real diff, drop the placeholder.
    observers[0]!(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    )
    await nextTick()
    expect(wrapper.find('[data-testid="center-diff-placeholder"]').exists()).toBe(false)
    const diff = wrapper.findComponent(SidebarDiffView)
    expect(diff.exists()).toBe(true)
    expect(diff.props('path')).toBe('foo.txt')
    expect(diff.props('added')).toBe(1)
    expect(disconnectMock).toHaveBeenCalled()
  })

  it('mounts immediately when IntersectionObserver is unavailable', async () => {
    vi.stubGlobal('IntersectionObserver', undefined)
    const wrapper = shallowMount(CenterDiffSection, { props: sectionProps })
    await flushPromises()
    expect(wrapper.findComponent(SidebarDiffView).exists()).toBe(true)
  })
})

describe('ChatView stacked center render', () => {
  it('holds the ordered file list + current path beside centerDiff', () => {
    expect(chatViewSrc).toMatch(/const centerFiles = ref<DiffSelection\[\]>\(\[\]\)/)
    expect(chatViewSrc).toMatch(/const currentPath = ref<string \| null>\(null\)/)
    expect(chatViewSrc).toMatch(/const centerDiff = ref<DiffSelection \| null>\(null\)/)
  })

  it('merges singles and lists, and scrolls to already-loaded files', () => {
    expect(chatViewSrc).toMatch(/function onChatSidebarShowDiff\(selection: DiffSelection\)/)
    expect(chatViewSrc).toMatch(/function onChatSidebarShowDiffList\(files: DiffSelection\[\]\)/)
    expect(chatViewSrc).toMatch(/@show-diff-list="onChatSidebarShowDiffList"/)
    expect(chatViewSrc).toMatch(/function scrollToCenterFile\(path: string\)/)
    expect(chatViewSrc).toMatch(/scrollToSectionElement\(path\)/)
  })

  it('stacks one lazy section per file in a dedicated scroll container', () => {
    expect(chatViewSrc).toMatch(/data-testid="chat-center-diff-scroll"/)
    expect(chatViewSrc).toMatch(/v-for="file in centerFiles"/)
    expect(chatViewSrc).toMatch(/:section-id="centerDiffSectionId\(file\.path\)"/)
    expect(chatViewSrc).toMatch(/data-testid="chat-center-diff-back"/)
    expect(chatViewSrc).toMatch(/@click="onCenterDiffBack"/)
  })

  it('hides messages+composer while any stacked diff shows', () => {
    expect(chatViewSrc).toMatch(/v-show="!showCenterStage"\s+ref="messagesWrapperRef"/)
  })

  it('header offers Copy all scoped to this diff', () => {
    expect(chatViewSrc).toMatch(/data-testid="chat-center-diff-copy-all"/)
    expect(chatViewSrc).toMatch(/v-if="reviewCommentsForDiff\.length > 0"/)
    expect(chatViewSrc).toMatch(/function copyAllReviewComments\(\)/)
    expect(chatViewSrc).toMatch(/reviewCommentsForDiff\.value\.map\(\(e\) => e\.formatted\)/)
    expect(chatViewSrc).toMatch(/copyTextToClipboard\(body\)/)
    expect(chatViewSrc).toMatch(/data-testid="chat-center-diff-copied-all"/)
  })

  it('opens only on explicit selection — list loads never auto-open', () => {
    // Refresh must land on chat even when the PR/diff fetch succeeds:
    // the gate ignores the preloaded list, and the list handler has no
    // first-file auto-select branch.
    expect(chatViewSrc).toMatch(
      /const showCenterDiff = computed\(\(\) => centerDiff\.value !== null\)/,
    )
    expect(chatViewSrc).not.toMatch(/else if \(merged\.length > 0\)/)
  })
})

/** CenterDiffSection — the collapse contract, and the ONE trap it hides. The `IntersectionObserver`
 * is the only automatic gate on mounting the heavy diff body, and a COLLAPSED section never
 * intersects. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { shallowMount, flushPromises } from '@vue/test-utils'
import { nextTick } from 'vue'
import CenterDiffSection from '../chat_right_sidebar/CenterDiffSection.vue'
import SidebarDiffView from '../chat_right_sidebar/SidebarDiffView.vue'

const observers: IntersectionObserverCallback[] = []
const observeMock = vi.fn()
const disconnectMock = vi.fn()

function stubObserver() {
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
}

const sectionProps = {
  sectionId: 'center-diff-Zm9v',
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

describe('CenterDiffSection collapse', () => {
  it('a section that STARTS expanded still waits for the observer (fast scroll stays intact)', async () => {
    stubObserver()
    const wrapper = shallowMount(CenterDiffSection, {
      props: { ...sectionProps, collapsed: false },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="center-diff-placeholder"]').exists()).toBe(true)
    expect(wrapper.findComponent(SidebarDiffView).exists()).toBe(false)
  })

  it('expanding a collapsed section mounts the body NOW, without the observer ever firing', async () => {
    stubObserver()
    const wrapper = shallowMount(CenterDiffSection, {
      props: { ...sectionProps, collapsed: true },
    })
    await flushPromises()
    expect(wrapper.findComponent(SidebarDiffView).exists()).toBe(false)

    await wrapper.setProps({ collapsed: false })
    await nextTick()
    // No observers[0](...) call anywhere: this is the eager path.
    const diff = wrapper.findComponent(SidebarDiffView)
    expect(diff.exists()).toBe(true)
    expect(diff.props('collapsed')).toBe(false)
  })

  it('passes the view controls down and forwards their toggles up', async () => {
    stubObserver()
    const wrapper = shallowMount(CenterDiffSection, {
      props: { ...sectionProps, collapsed: false, mode: 'split', wholeFile: true, untracked: true },
    })
    observers[0]!(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    )
    await nextTick()
    const diff = wrapper.findComponent(SidebarDiffView)
    expect(diff.props('mode')).toBe('split')
    expect(diff.props('wholeFile')).toBe(true)
    expect(diff.props('untracked')).toBe(true)

    diff.vm.$emit('toggle-collapse')
    diff.vm.$emit('toggle-whole-file')
    expect(wrapper.emitted('toggle-collapse')).toHaveLength(1)
    expect(wrapper.emitted('toggle-whole-file')).toHaveLength(1)
  })

  it('collapsing drops the rendered body but keeps the header + anchor id (?diff= can still find it)', async () => {
    stubObserver()
    const wrapper = shallowMount(CenterDiffSection, {
      props: { ...sectionProps, collapsed: false },
    })
    observers[0]!(
      [{ isIntersecting: true } as IntersectionObserverEntry],
      {} as IntersectionObserver,
    )
    await nextTick()
    const diff = wrapper.findComponent(SidebarDiffView)
    expect(diff.exists()).toBe(true)
    expect(diff.props('collapsed')).toBe(false)

    await wrapper.setProps({ collapsed: true })
    await nextTick()
    // `collapsed` reaches the view (which keeps its header and drops the table — asserted directly
    // in SidebarDiffView.split.spec.ts), and the section keeps its anchor id, so ?diff= / a sidebar
    // click can still find and re-expand it.
    expect(diff.props('collapsed')).toBe(true)
    expect(wrapper.get('[data-testid="center-diff-section"]').attributes('id')).toBe(
      sectionProps.sectionId,
    )
  })
})

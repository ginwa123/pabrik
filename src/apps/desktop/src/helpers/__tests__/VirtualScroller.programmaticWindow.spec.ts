/** A programmatic scroll must move the rendered window in the same tick it moves `scrollTop`:
 * `visibleRange` derives from the scroller's own ref, which only the native event used to write.
 */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

const VIEWPORT = 800
const ROW = 200
const COUNT = 100

interface Item {
  id: string
}

function mkItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: `i${i}` }))
}

Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return VIEWPORT
  },
})

Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    const sizer = (this as HTMLElement).querySelector?.('.virtual-scroller-sizer')
    return sizer ? parseFloat((sizer as HTMLElement).style.height) || 0 : 0
  },
})

interface Exposed {
  scrollToIndex: (index: number, behavior?: ScrollBehavior) => void
  scrollToPosition: (scrollTop: number, behavior?: ScrollBehavior) => void
  effectiveRange: { start: number; end: number }
}

function mountScroller() {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: mkItems(COUNT),
      buffer: 5,
      defaultItemHeight: ROW,
      totalCount: COUNT,
      itemKey: (item: unknown) => (item as Item).id,
    },
  })
  return { wrapper, el: wrapper.element as HTMLElement, vm: wrapper.vm as Exposed }
}

async function settle(): Promise<void> {
  await nextTick()
  await new Promise<void>((r) => setTimeout(r, 150))
  await nextTick()
}

describe('VirtualScroller — a programmatic scroll moves the rendered window with it', () => {
  it('scrollToIndex renders the target window without waiting for a scroll event', async () => {
    const { wrapper, el, vm } = mountScroller()
    await settle()

    expect(vm.effectiveRange.end).toBeLessThan(COUNT)

    vm.scrollToIndex(95)
    await nextTick()

    expect(el.scrollTop).toBe(95 * ROW)
    expect(vm.effectiveRange.end).toBe(COUNT)
    expect(vm.effectiveRange.start).toBeGreaterThan(COUNT - 20)
    wrapper.unmount()
  })

  it('scrollToPosition renders the restored window without waiting for a scroll event', async () => {
    const { wrapper, vm } = mountScroller()
    await settle()

    vm.scrollToPosition(9000)
    await nextTick()

    expect(vm.effectiveRange.start).toBeGreaterThan(0)
    expect(vm.effectiveRange.end).toBeLessThan(COUNT)
    expect(vm.effectiveRange.start).toBeLessThanOrEqual(45)
    expect(vm.effectiveRange.end).toBeGreaterThanOrEqual(45)
    wrapper.unmount()
  })

  it('a smooth scroll leaves the window to the animation instead of teleporting it', async () => {
    const { wrapper, vm } = mountScroller()
    await settle()

    const before = { ...vm.effectiveRange }
    vm.scrollToPosition(9000, 'smooth')
    await nextTick()

    expect(vm.effectiveRange).toEqual(before)
    wrapper.unmount()
  })
})

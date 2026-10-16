/** P2 structural tests for VirtualScroller.vue (task_1787551495337_9, "make virtual scroller more
 * smooth"). What P2 changes, and what each test pins: 1. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: number }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

function mountScroller(props: {
  items: Item[]
  buffer?: number
  defaultItemHeight?: number
  clientHeight?: number
}) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: props.items,
      buffer: props.buffer ?? 20,
      defaultItemHeight: props.defaultItemHeight ?? 200,
      totalCount: props.items.length,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', {
    value: props.clientHeight ?? 800,
    configurable: true,
  })
  Object.defineProperty(el, 'scrollHeight', {
    value: props.items.length * (props.defaultItemHeight ?? 200),
    configurable: true,
  })
  return { wrapper, el }
}

describe('VirtualScroller sizer + transform DOM contract', () => {
  it('renders NO spacer divs and exactly one sizer sized to total content height', async () => {
    // 50 items × 200px = 10000px total.
    const { wrapper, el } = mountScroller({ items: makeItems(50), buffer: 2 })
    await nextTick()

    expect(el.querySelectorAll('.virtual-scroller-spacer').length).toBe(0)
    const sizer = el.querySelector('.virtual-scroller-sizer')
    expect(sizer).toBeTruthy()
    const sizerPx = parseFloat((sizer as HTMLElement).style.height)
    // Total = Σ stored/estimated heights = 50 × 200 = 10000.
    expect(sizerPx).toBe(10000)
    wrapper.unmount()
  })

  it('positions the content window with translate3d(0, topSpacer px, 0)', async () => {
    const { wrapper, el } = mountScroller({ items: makeItems(100), buffer: 5 })
    await nextTick()

    // Scroll to middle: scrollTop=10000 → startIndex=50 → start=45.
    // topSpacer = accumulated[45] = 45 × 200 = 9000.
    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content') as HTMLElement
    expect(content).toBeTruthy()
    expect(content.style.transform).toBe('translate3d(0px, 9000px, 0px)')
    wrapper.unmount()
  })

  it('keeps scroll math identical: renderedCount still 2*buffer+visible after the swap', async () => {
    const { wrapper, el } = mountScroller({ items: makeItems(100), buffer: 20 })
    await nextTick()
    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const vm = wrapper.vm as unknown as { renderedCount: number }
    expect(vm.renderedCount).toBe(44)
    wrapper.unmount()
  })
})

describe('VirtualScroller contentShift emit', () => {
  it('emits contentShift with {topSpacer, bottomSpacer, total} when positioning values change', async () => {
    const { wrapper, el } = mountScroller({ items: makeItems(100), buffer: 5 })
    await nextTick()

    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const events = wrapper.emitted<[shift: { topSpacer: number; bottomSpacer: number; total: number }]>(
      'contentShift',
    )
    expect(events).toBeTruthy()
    const last = events![events!.length - 1]![0]
    // start=45 → topSpacer=9000; end=59+... visible 4 + buffer → end=74?
    // scrollTop=10000, viewBottom=10800 → endIndex=54 → end=59.
    // bottomSpacer = 100×200 − 59×200 = 8200. total = 20000.
    expect(last.topSpacer).toBe(9000)
    expect(last.bottomSpacer).toBe(8200)
    expect(last.total).toBe(20000)
    wrapper.unmount()
  })

  it('does NOT emit contentShift when nothing changed', async () => {
    const { wrapper, el } = mountScroller({ items: makeItems(100), buffer: 5 })
    await nextTick()

    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()
    const afterFirst = wrapper.emitted('contentShift')!.length

    // Same position again — values unchanged → no new emit.
    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(wrapper.emitted('contentShift')!.length).toBe(afterFirst)
    wrapper.unmount()
  })
})

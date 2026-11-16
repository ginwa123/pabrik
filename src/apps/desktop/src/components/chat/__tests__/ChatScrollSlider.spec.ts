import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import ChatScrollSlider from '../ChatScrollSlider.vue'
import { computeThumbGeometry } from '../chatScrollSlider'

/** Dispatch a pointer-type event with coordinates (test-utils `trigger` cannot set clientX/clientY — it assigns onto a getter-only MouseEvent). */
function firePointer(
  el: HTMLElement,
  type: string,
  init: { clientX?: number; clientY?: number } = {},
) {
  const evt = new MouseEvent(type, { bubbles: true, cancelable: true, ...init })
  el.dispatchEvent(evt)
}
function mockScrollMetrics(
  el: HTMLElement,
  metrics: { scrollTop: number; scrollHeight: number; clientHeight: number },
) {
  Object.defineProperty(el, 'scrollTop', {
    configurable: true,
    writable: true,
    value: metrics.scrollTop,
  })
  Object.defineProperty(el, 'scrollHeight', { configurable: true, value: metrics.scrollHeight })
  Object.defineProperty(el, 'clientHeight', { configurable: true, value: metrics.clientHeight })
}

function mockTrackSizes(track: HTMLElement, thumb: HTMLElement, trackH = 500, thumbH = 100) {
  Object.defineProperty(track, 'clientHeight', { configurable: true, value: trackH })
  Object.defineProperty(thumb, 'clientHeight', { configurable: true, value: thumbH })
  track.getBoundingClientRect = () => ({ top: 0, height: trackH }) as DOMRect
}

describe('computeThumbGeometry', () => {
  it('is hidden when content fits the viewport', () => {
    expect(computeThumbGeometry(0, 400, 500).visible).toBe(false)
    expect(computeThumbGeometry(0, 500, 500).visible).toBe(false)
  })

  it('is visible with proportional height when scrollable', () => {
    const g = computeThumbGeometry(0, 2000, 500)
    expect(g.visible).toBe(true)
    expect(g.thumbHeightPct).toBeCloseTo(25, 5)
    expect(g.thumbTopPct).toBeCloseTo(0, 5)
    expect(g.ratio).toBeCloseTo(0, 5)
  })

  it('moves the thumb down as scrollTop grows (realtime sync math)', () => {
    const top = computeThumbGeometry(0, 2000, 500)
    const mid = computeThumbGeometry(750, 2000, 500)
    const bottom = computeThumbGeometry(1500, 2000, 500)
    expect(mid.thumbTopPct).toBeGreaterThan(top.thumbTopPct)
    expect(bottom.thumbTopPct).toBeGreaterThan(mid.thumbTopPct)
    expect(bottom.ratio).toBeCloseTo(1, 5)
  })

  it('clamps tiny content to a grabbable minimum thumb', () => {
    const g = computeThumbGeometry(0, 20000, 500)
    expect(g.thumbHeightPct).toBeGreaterThanOrEqual(8)
  })

  it('hides on non-finite input instead of NaN-positioning the thumb', () => {
    expect(computeThumbGeometry(NaN, 2000, 500).visible).toBe(false)
  })
})

describe('ChatScrollSlider', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('stays hidden when the chat fits without scrolling', () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 0, scrollHeight: 400, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="chat-scroll-slider"]').isVisible()).toBe(false)
    wrapper.unmount()
  })

  it('shows a proportional thumb when the chat overflows', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 0, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    const track = wrapper.find('[data-testid="chat-scroll-slider"]')
    expect(track.isVisible()).toBe(true)
    const thumb = wrapper.find('[data-testid="chat-scroll-thumb"]')
    expect(thumb.attributes('style')).toContain('height: 25%')
    wrapper.unmount()
  })

  it('moves the thumb in realtime when the user scrolls up', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 1500, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    const before = wrapper.find('[data-testid="chat-scroll-thumb"]').attributes('style') ?? ''
    // User scrolls up: scrollTop drops, thumb must follow on the next scroll event.
    container.scrollTop = 500
    container.dispatchEvent(new Event('scroll'))
    vi.advanceTimersByTime(32) // flush the rAF-throttled sync
    await wrapper.vm.$nextTick()
    const after = wrapper.find('[data-testid="chat-scroll-thumb"]').attributes('style') ?? ''
    expect(after).not.toBe(before)
    expect(after).toContain('top: 25%')
    wrapper.unmount()
  })

  it('drags the thumb to scrub the chat (pointer drag writes scrollTop)', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 0, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    const track = wrapper.find('[data-testid="chat-scroll-slider"]').element as HTMLElement
    const thumb = wrapper.find('[data-testid="chat-scroll-thumb"]')
    mockTrackSizes(track, thumb.element as HTMLElement, 500, 125)
    firePointer(thumb.element as HTMLElement, 'pointerdown', { clientY: 100 })
    await wrapper.vm.$nextTick()
    // Drag down 100px of the 375px travel => 100/375 of the 1500px range = 400px.
    firePointer(thumb.element as HTMLElement, 'pointermove', { clientY: 200 })
    await wrapper.vm.$nextTick()
    expect(container.scrollTop).toBeCloseTo(400, 0)
    firePointer(thumb.element as HTMLElement, 'pointerup')
    wrapper.unmount()
  })

  it('track click jumps the chat (native scrollbar parity)', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 0, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    const track = wrapper.find('[data-testid="chat-scroll-slider"]')
    const trackEl = track.element as HTMLElement
    const thumbEl = wrapper.find('[data-testid="chat-scroll-thumb"]').element as HTMLElement
    mockTrackSizes(trackEl, thumbEl, 500, 125)
    // Click mid-track: target IS the track (not the thumb) => jump.
    firePointer(trackEl, 'pointerdown', { clientX: 6, clientY: 250 })
    await wrapper.vm.$nextTick()
    expect(container.scrollTop).toBeGreaterThan(0)
    wrapper.unmount()
  })

  it('keyboard arrows scrub when the thumb is focused', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 500, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    const thumb = wrapper.find('[data-testid="chat-scroll-thumb"]')
    await thumb.trigger('keydown', { key: 'ArrowUp' })
    expect(container.scrollTop).toBeLessThan(500)
    await thumb.trigger('keydown', { key: 'End' })
    expect(container.scrollTop).toBe(1500)
    wrapper.unmount()
  })

  it('exposes aria-valuenow reflecting the scroll ratio', async () => {
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 750, scrollHeight: 2000, clientHeight: 500 })
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => container },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="chat-scroll-thumb"]').attributes('aria-valuenow')).toBe('50')
    wrapper.unmount()
  })

  it('attaches late when getContainer starts returning an element', async () => {
    let el: HTMLElement | null = null
    const wrapper = mount(ChatScrollSlider, {
      props: { getContainer: () => el },
      attachTo: document.body,
    })
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="chat-scroll-slider"]').isVisible()).toBe(false)
    const container = document.createElement('div')
    mockScrollMetrics(container, { scrollTop: 0, scrollHeight: 2000, clientHeight: 500 })
    el = container
    vi.advanceTimersByTime(600)
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="chat-scroll-slider"]').isVisible()).toBe(true)
    wrapper.unmount()
  })
})

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import TopLoadingBar from '../components/shell/TopLoadingBar.vue'
import { useLoadingStore } from '../stores/loading'

describe('TopLoadingBar', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.useFakeTimers()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  function mountBar() {
    wrapper = mount(TopLoadingBar, {
      global: { plugins: [createPinia()] },
    })
    // The component's own pinia instance is separate from the test's; drive visibility through the mounted instance's store instead.
    return wrapper
  }

  it('renders nothing when idle', async () => {
    mountBar()
    await vi.advanceTimersByTimeAsync(500)
    expect(wrapper!.find('[data-testid="top-loading-bar"]').exists()).toBe(false)
  })

  it('debounces fast requests: no bar when busy clears before 150ms', async () => {
    const w = mountBar()
    const store = useLoadingStore(w.vm.$pinia)
    store.startApi()
    await vi.advanceTimersByTimeAsync(100)
    expect(w.find('[data-testid="top-loading-bar"]').exists()).toBe(false)
    store.finishApi()
    await vi.advanceTimersByTimeAsync(500)
    expect(w.find('[data-testid="top-loading-bar"]').exists()).toBe(false)
  })

  it('shows the bar once busy for longer than 150ms, hides immediately after', async () => {
    const w = mountBar()
    const store = useLoadingStore(w.vm.$pinia)
    store.startApi()
    await vi.advanceTimersByTimeAsync(151)
    expect(w.find('[data-testid="top-loading-bar"]').exists()).toBe(true)
    store.finishApi()
    await vi.advanceTimersByTimeAsync(0)
    expect(w.find('[data-testid="top-loading-bar"]').exists()).toBe(false)
  })

  it('shows the bar for route navigation too', async () => {
    const w = mountBar()
    const store = useLoadingStore(w.vm.$pinia)
    store.startRoute()
    await vi.advanceTimersByTimeAsync(151)
    expect(w.find('[data-testid="top-loading-bar"]').exists()).toBe(true)
  })
})

import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import VirtualScroller from '../helpers/VirtualScroller.vue'

const items = [{ id: 'a' }, { id: 'b' }]

describe('VirtualScroller unmount', () => {
  afterEach(() => vi.useRealTimers())

  it('leaves no pending timer behind when it unmounts', async () => {
    vi.useFakeTimers()
    const wrapper = mount(VirtualScroller, {
      props: { items, itemKey: (item: unknown) => (item as { id: string }).id },
      slots: { default: '<div class="row">row</div>' },
      attachTo: document.body,
    })
    await nextTick()
    expect(vi.getTimerCount()).toBeGreaterThan(0)

    wrapper.unmount()

    expect(vi.getTimerCount()).toBe(0)
  })
})

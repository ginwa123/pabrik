import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import UserPillRail, { type UserPill } from '../UserPillRail.vue'

const pills: UserPill[] = [
  { groupIndex: 0, key: 'msg-1', preview: 'hello world' },
  { groupIndex: 3, key: 'msg-4', preview: 'second question' },
  { groupIndex: 7, key: 'msg-8', preview: 'third one here' },
]

describe('UserPillRail', () => {
  it('renders one pill per user group', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    expect(wrapper.findAll('[data-testid="user-pill"]').length).toBe(3)
    wrapper.unmount()
  })

  it('renders an accessible label per pill and no native tooltip', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    const buttons = wrapper.findAll('[data-testid="user-pill"]')
    expect(buttons[0]!.attributes('aria-label')).toBe('Jump to message: hello world')
    // The styled message box is the single affordance now. A native `title` would ALSO fire, so the
    // user would see the OS tooltip appear next to (or on top of) the box — two previews for one
    // hover. Assert it is gone, not merely unused.
    expect(buttons[0]!.attributes('title')).toBeUndefined()
    expect(wrapper.find('[data-testid="user-pill-rail"]').attributes('aria-label')).toBe(
      'Jump to user messages',
    )
    wrapper.unmount()
  })

  it('click emits jump with the pill groupIndex + stable key', async () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: null },
      attachTo: document.body,
    })
    await wrapper.findAll('[data-testid="user-pill"]')[1]!.trigger('click')
    expect(wrapper.emitted('jump')).toEqual([[3, 'msg-4']])
    wrapper.unmount()
  })

  it('highlights only the active pill', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills, activeGroupIndex: 3 },
      attachTo: document.body,
    })
    const buttons = wrapper.findAll('[data-testid="user-pill"]')
    expect(buttons[0]!.classes()).not.toContain('user-pill--active')
    expect(buttons[1]!.classes()).toContain('user-pill--active')
    expect(buttons[2]!.classes()).not.toContain('user-pill--active')
    wrapper.unmount()
  })

  it('renders no pills for an empty list', () => {
    const wrapper = mount(UserPillRail, {
      props: { pills: [], activeGroupIndex: null },
      attachTo: document.body,
    })
    expect(wrapper.findAll('[data-testid="user-pill"]').length).toBe(0)
    wrapper.unmount()
  })
})

describe('UserPillRail — hover/focus message box', () => {
  const mountRail = (activeGroupIndex: number | null = null) =>
    mount(UserPillRail, {
      props: { pills, activeGroupIndex },
      attachTo: document.body,
    })

  it('shows no message box until a pill is hovered', () => {
    const wrapper = mountRail()
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('hovering a pill opens a box with that message text', async () => {
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[1]!.trigger('mouseenter')
    const box = wrapper.find('[data-testid="user-pill-message"]')
    expect(box.exists()).toBe(true)
    expect(box.text()).toBe('second question')
    wrapper.unmount()
  })

  it('leaving the pill closes the box', async () => {
    const wrapper = mountRail()
    const pill = wrapper.findAll('[data-testid="user-pill"]')[0]!
    await pill.trigger('mouseenter')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(true)
    await pill.trigger('mouseleave')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('moving between pills swaps the box instead of blanking it', async () => {
    // `mouseleave` on the pill being LEFT can arrive after `mouseenter` on the next one. An
    // unguarded close would blank the box the user just moved to — the box would flicker off on
    // every pill-to-pill move, which is the whole point of the feature.
    const wrapper = mountRail()
    const [first, second] = wrapper.findAll('[data-testid="user-pill"]')
    await first!.trigger('mouseenter')
    await second!.trigger('mouseenter')
    await first!.trigger('mouseleave')
    const box = wrapper.find('[data-testid="user-pill-message"]')
    expect(box.exists()).toBe(true)
    expect(box.text()).toBe('second question')
    wrapper.unmount()
  })

  it('keyboard focus opens the box too, so tabbing gets the same preview', async () => {
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[2]!.trigger('focus')
    const box = wrapper.find('[data-testid="user-pill-message"]')
    expect(box.exists()).toBe(true)
    expect(box.text()).toBe('third one here')
    wrapper.unmount()
  })

  it('blur closes the box', async () => {
    const wrapper = mountRail()
    const pill = wrapper.findAll('[data-testid="user-pill"]')[0]!
    await pill.trigger('focus')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(true)
    await pill.trigger('blur')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('leaving the rail entirely closes the box', async () => {
    // The pointer can exit the rail through the gap between pills (the
    // rail has padding, and the box itself is pointer-events:none), so
    // the rail needs its own leave as a backstop.
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[0]!.trigger('mouseenter')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(true)
    await wrapper.find('[data-testid="user-pill-rail"]').trigger('mouseleave')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('the box is aria-hidden — the pill aria-label already carries the text', async () => {
    // Without this a screen reader reads every message twice while
    // tabbing the rail: once from the button's label, once from the box.
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[0]!.trigger('mouseenter')
    expect(wrapper.find('[data-testid="user-pill-message"]').attributes('aria-hidden')).toBe('true')
    wrapper.unmount()
  })

  it('the box is aligned to the pill that opened it, not to the rail middle', async () => {
    // The rail is a uniform stack, so the box's `top` is derived from the open pill's index. A box
    // pinned at the rail's centre would sit level with the wrong pill whenever the hovered one is
    // not the middle one — which is most of the time.
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[2]!.trigger('mouseenter')
    const top = wrapper.find('[data-testid="user-pill-message"]').attributes('style')
    expect(top).toContain('top')
    // Index 2 → 2 pitches down from the first pill's centre.
    expect(top).toContain('2 * var(--pill-pitch)')
    wrapper.unmount()
  })

  it('the active pill box carries the accent class', async () => {
    const wrapper = mountRail(3)
    await wrapper.findAll('[data-testid="user-pill"]')[1]!.trigger('mouseenter')
    expect(wrapper.find('[data-testid="user-pill-message"]').classes()).toContain(
      'user-pill-message--active',
    )
    wrapper.unmount()
  })

  it('a pill whose key vanished (SSE regroup) closes the box rather than erroring', async () => {
    // `openPill` resolves by key; if the group disappears between hover
    // and render the lookup must degrade to "no box", not throw.
    const wrapper = mountRail()
    await wrapper.findAll('[data-testid="user-pill"]')[0]!.trigger('mouseenter')
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(true)
    await wrapper.setProps({ pills: pills.slice(1) })
    expect(wrapper.find('[data-testid="user-pill-message"]').exists()).toBe(false)
    wrapper.unmount()
  })
})

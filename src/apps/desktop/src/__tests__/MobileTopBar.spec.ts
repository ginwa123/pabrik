import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import MobileTopBar from '../components/appLayout/MobileTopBar.vue'

describe('MobileTopBar', () => {
  it('shows the title of what the reader is looking at', () => {
    const wrapper = mount(MobileTopBar, { props: { title: 'task_1794693919804_6' } })
    expect(wrapper.text()).toContain('task_1794693919804_6')
  })

  it('falls back to the product name when nothing is selected', () => {
    const wrapper = mount(MobileTopBar, { props: { title: '' } })
    expect(wrapper.text()).toContain('Pabrik')
  })

  it('emits toggleNav when the menu button is pressed', async () => {
    const wrapper = mount(MobileTopBar, { props: { title: 'Pabrik' } })
    await wrapper.get('[data-testid="mobile-nav-toggle"]').trigger('click')
    expect(wrapper.emitted('toggleNav')).toHaveLength(1)
  })

  it('gives the menu button a name a screen reader can read', () => {
    const wrapper = mount(MobileTopBar, { props: { title: 'Pabrik' } })
    const toggle = wrapper.get('[data-testid="mobile-nav-toggle"]')
    expect(toggle.attributes('aria-label')).toBeTruthy()
    expect(toggle.attributes('aria-expanded')).toBe('false')
  })

  it('tells a screen reader when the drawer is already open', () => {
    const wrapper = mount(MobileTopBar, { props: { title: 'Pabrik', navOpen: true } })
    expect(wrapper.get('[data-testid="mobile-nav-toggle"]').attributes('aria-expanded')).toBe('true')
  })
})

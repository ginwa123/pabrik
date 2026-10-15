// ChatAppBar — the ONE app bar shared by every workspace-item chat mode (kanban / agent / standard
// folder-chat). These tests pin the bar's contract so the three modes cannot drift apart again.
// Pre-fix each mode hand-rolled its own bar: agent mode had a full-width `px-5 py-3` header with a
// text "✕ Close" button and no sidebar toggle, kanban mode had a `h-11` bar beside the sidebar, and
// folder mode had no bar at all.

import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import ChatAppBar from '../components/views/ChatAppBar.vue'

describe('ChatAppBar', () => {
  it('renders the title as the truncating flex-1 label', () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'gitlab support' } })
    const title = wrapper.get('[data-testid="chat-app-bar-title"]')
    expect(title.text()).toBe('gitlab support')
    expect(title.classes()).toContain('truncate')
    expect(title.classes()).toContain('flex-1')
    expect(title.attributes('style')).toContain('var(--semantic-text)')
  })

  it('locks the bar height / padding / background so all modes match', () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    // h-11 (44px) + px-3, sidebar background, 1px bottom border.
    expect(bar.classes()).toContain('h-11')
    expect(bar.classes()).toContain('px-3')
    expect(bar.attributes('style')).toContain('var(--semantic-sidebar-bg)')
    expect(bar.attributes('style')).toContain('border-bottom: 1px solid var(--color-border)')
  })

  it('renders the sidebar toggle and the close button in a stable order', () => {
    const wrapper = mount(ChatAppBar, {
      props: { title: 'X' },
      slots: { extras: '<span data-testid="extra-bit">busy</span>' },
    })
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-app-bar-close"]').exists()).toBe(true)
    // extras slot renders between the title and the two buttons.
    const html = wrapper.html()
    expect(html.indexOf('chat-app-bar-title')).toBeLessThan(html.indexOf('extra-bit'))
    expect(html.indexOf('extra-bit')).toBeLessThan(html.indexOf('chat-app-bar-sidebar-toggle'))
    expect(html.indexOf('chat-app-bar-sidebar-toggle')).toBeLessThan(
      html.indexOf('chat-app-bar-close'),
    )
  })

  it('emits toggle-sidebar when the ◫ button is clicked', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    await wrapper.get('[data-testid="chat-app-bar-sidebar-toggle"]').trigger('click')
    expect(wrapper.emitted('toggle-sidebar')).toHaveLength(1)
    expect(wrapper.emitted('close')).toBeUndefined()
  })

  it('emits close when the ✕ button is clicked', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    await wrapper.get('[data-testid="chat-app-bar-close"]').trigger('click')
    expect(wrapper.emitted('close')).toHaveLength(1)
    expect(wrapper.emitted('toggle-sidebar')).toBeUndefined()
  })

  it('hides the sidebar toggle when the host does not own a chat sidebar', () => {
    const wrapper = mount(ChatAppBar, {
      props: { title: 'X', showSidebarToggle: false },
    })
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(false)
    // The close affordance is NOT optional — every task chat is closable.
    expect(wrapper.find('[data-testid="chat-app-bar-close"]').exists()).toBe(true)
  })

  it('renders the extras slot before the buttons', () => {
    const wrapper = mount(ChatAppBar, {
      props: { title: 'X' },
      slots: { extras: '<span data-testid="extra-bit">busy</span>' },
    })
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    expect(bar.find('[data-testid="extra-bit"]').exists()).toBe(true)
  })

  it('carries a stable testid and a11y label on the close button', () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const close = wrapper.get('[data-testid="chat-app-bar-close"]')
    expect(close.attributes('aria-label')).toBe('Close chat')
    expect(close.attributes('type')).toBe('button')
  })
})

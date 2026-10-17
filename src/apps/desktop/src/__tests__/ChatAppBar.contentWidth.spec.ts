/** The app bar's transcript-width control: its label, its cycling, its memory. */
import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import ChatAppBar from '../components/views/ChatAppBar.vue'
import {
  CHAT_CONTENT_WIDTH_STORAGE_KEY,
  useChatContentWidth,
} from '../composables/useChatContentWidth'
import { makeLocalStorageStub } from './helpers'

const labelOf = (wrapper: { get: (s: string) => { text: () => string } }) =>
  wrapper.get('[data-testid="chat-app-bar-width-label"]').text()

describe('ChatAppBar transcript width control', () => {
  const { setWidth } = useChatContentWidth()

  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    setWidth('full')
  })

  it('shows the current preset and steps to the next one on click', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const button = wrapper.get('[data-testid="chat-app-bar-width-toggle"]')
    expect(labelOf(wrapper)).toBe('Full')
    expect(button.attributes('aria-label')).toBe('Transcript width: Full. Click for Comfortable.')
    await button.trigger('click')
    expect(labelOf(wrapper)).toBe('Comfortable')
    await button.trigger('click')
    expect(labelOf(wrapper)).toBe('Wide')
    await button.trigger('click')
    expect(labelOf(wrapper)).toBe('Full')
  })

  it('persists each click, so the choice survives a reload', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    await wrapper.get('[data-testid="chat-app-bar-width-toggle"]').trigger('click')
    expect(globalThis.localStorage.getItem(CHAT_CONTENT_WIDTH_STORAGE_KEY)).toBe('comfortable')
  })

  it('is a plain button that never emits the bar close or sidebar events', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const button = wrapper.get('[data-testid="chat-app-bar-width-toggle"]')
    expect(button.attributes('type')).toBe('button')
    await button.trigger('click')
    expect(wrapper.emitted('close')).toBeUndefined()
    expect(wrapper.emitted('toggle-sidebar')).toBeUndefined()
  })

  it('renders between the extras slot and the sidebar toggle', () => {
    const wrapper = mount(ChatAppBar, {
      props: { title: 'X' },
      slots: { extras: '<span data-testid="extra-bit">busy</span>' },
    })
    const html = wrapper.html()
    expect(html.indexOf('extra-bit')).toBeLessThan(html.indexOf('chat-app-bar-width-toggle'))
    expect(html.indexOf('chat-app-bar-width-toggle')).toBeLessThan(
      html.indexOf('chat-app-bar-sidebar-toggle'),
    )
  })
})

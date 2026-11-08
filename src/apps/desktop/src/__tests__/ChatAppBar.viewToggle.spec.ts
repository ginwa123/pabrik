/** The app bar's grouped/raw toggle: it renders, it flips, and it sits in the right cluster. */
import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import ChatAppBar from '../components/views/ChatAppBar.vue'
import { setChatViewMode } from '../stores/chatView'

const labelOf = (wrapper: { get: (s: string) => { text: () => string } }) =>
  wrapper.get('[data-testid="chat-app-bar-view-label"]').text()

describe('ChatAppBar view toggle', () => {
  beforeEach(() => setChatViewMode('dev'))

  it('shows the current view and flips it on click', async () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const button = wrapper.get('[data-testid="chat-app-bar-view-toggle"]')
    expect(labelOf(wrapper)).toBe('Grouped')
    expect(button.attributes('aria-label')).toBe('View: Grouped. Click for Rows.')

    await button.trigger('click')
    expect(labelOf(wrapper)).toBe('Rows')
    expect(button.attributes('aria-label')).toBe('View: Rows. Click for Grouped.')

    await button.trigger('click')
    expect(labelOf(wrapper)).toBe('Grouped')
  })

  it('renders before the transcript-width control, in the same right cluster', () => {
    const wrapper = mount(ChatAppBar, { props: { title: 'X' } })
    const view = wrapper.get('[data-testid="chat-app-bar-view-toggle"]')
    const width = wrapper.get('[data-testid="chat-app-bar-width-toggle"]')
    expect(view.element.parentElement).toBe(width.element.parentElement)
    expect(
      view.element.compareDocumentPosition(width.element) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
  })
})

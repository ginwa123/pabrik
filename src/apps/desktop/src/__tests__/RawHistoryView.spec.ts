/** RawHistoryView: one line per row, the delete round-trip, undo, and drop-from-context. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { nextTick } from 'vue'

const mocks = vi.hoisted(() => ({
  deleteMessage: vi.fn(),
  restoreMessage: vi.fn(),
  setMessageFeed: vi.fn(),
}))

vi.mock('../api', () => mocks)

import RawHistoryView from '../components/views/chat_view/RawHistoryView.vue'
import type { Message } from '../components/views/chat_view/useChatMessagePresentation'

const row = (id: string, over: Partial<Message> = {}): Message => ({
  id,
  role: 'assistant',
  content: `text ${id}`,
  timestamp: new Date(0),
  ...over,
})

const mountView = (messages: Message[]) =>
  mount(RawHistoryView, { props: { sessionId: 's1', messages }, attachTo: document.body })

const panel = () => document.querySelector('[data-testid="raw-history-menu"]')

describe('RawHistoryView', () => {
  beforeEach(() => {
    mocks.deleteMessage.mockReset()
    mocks.restoreMessage.mockReset()
    mocks.setMessageFeed.mockReset()
  })

  it('draws one line per row, including the ones the grouped view never draws', () => {
    const wrapper = mountView([
      row('m1', { role: 'user', content: 'hi' }),
      row('m2', { content: '' }),
      row('m3', { role: 'tool', tool_name: 'kanban_list', content: '{"ok":true}' }),
    ])
    expect(wrapper.findAll('[data-testid^="raw-row-"]')).toHaveLength(3)
    expect(wrapper.get('[data-testid="raw-row-m2"]').text()).toContain('no text, tool call only')
    expect(wrapper.get('[data-testid="raw-row-m3"]').text()).toContain('kanban_list')
    wrapper.unmount()
  })

  it('deletes one row, shows the strip, and puts it back on undo', async () => {
    mocks.deleteMessage.mockResolvedValue({ deleted: { row: { id: 'm2' } } })
    mocks.restoreMessage.mockResolvedValue({ restored: { id: 'm2' } })

    const wrapper = mountView([row('m1'), row('m2')])
    await wrapper.get('[data-testid="raw-more-m2"]').trigger('click')
    await nextTick()
    expect(panel()).not.toBeNull()

    const deleteItem = Array.from(panel()!.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Delete message'),
    )!
    deleteItem.click()
    await nextTick()

    await wrapper.get('[data-testid="raw-confirm-delete-m2"]').trigger('click')
    await flushPromises()

    expect(mocks.deleteMessage).toHaveBeenCalledWith('m2')
    expect(wrapper.find('[data-testid="raw-row-m2"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="raw-history-strip"]').text()).toContain('Row deleted')
    expect(wrapper.emitted('changed')).toBeTruthy()

    await wrapper.get('[data-testid="raw-history-strip"] button').trigger('click')
    await flushPromises()

    expect(mocks.restoreMessage).toHaveBeenCalled()
    expect(wrapper.find('[data-testid="raw-row-m2"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="raw-history-strip"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('drops a row from the model context without deleting it', async () => {
    mocks.setMessageFeed.mockResolvedValue({ id: 'm1', is_feed_to_llm: false })

    const wrapper = mountView([row('m1')])
    await wrapper.get('[data-testid="raw-more-m1"]').trigger('click')
    await nextTick()

    const dropItem = Array.from(panel()!.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Drop from context'),
    )!
    dropItem.click()
    await flushPromises()

    expect(mocks.setMessageFeed).toHaveBeenCalledWith('m1', false)
    expect(wrapper.find('[data-testid="raw-row-m1"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="raw-feed-m1"]').text()).toBe('dropped')
    wrapper.unmount()
  })

  it('surfaces a failed delete instead of pretending the row went', async () => {
    mocks.deleteMessage.mockRejectedValue(new Error('boom'))

    const wrapper = mountView([row('m1')])
    await wrapper.get('[data-testid="raw-more-m1"]').trigger('click')
    await nextTick()
    const deleteItem = Array.from(panel()!.querySelectorAll('button')).find((b) =>
      b.textContent?.includes('Delete message'),
    )!
    deleteItem.click()
    await nextTick()
    await wrapper.get('[data-testid="raw-confirm-delete-m1"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="raw-row-m1"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="raw-history-error"]').text()).toContain('boom')
    wrapper.unmount()
  })
})

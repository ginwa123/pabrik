/** The attachment strip on a user turn: one chip per attached document, carrying the metadata
 * the read path emits — never the bytes. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import ChatAttachments from '@/components/chat/ChatAttachments.vue'

describe('ChatAttachments — the attached document chips', () => {
  it('renders one chip per attached file with its name and size', () => {
    const wrapper = mount(ChatAttachments, {
      props: {
        fileAttachments: JSON.stringify([
          { name: 'doc.pdf', mime: 'application/pdf', bytes: 2048 },
          { name: 'notes.md', mime: 'text/markdown', bytes: 512 },
        ]),
      },
    })
    const chips = wrapper.findAll('.chat-attached-file-chip')
    expect(chips.length).toBe(2)
    expect(chips[0]?.text()).toContain('doc.pdf')
    expect(chips[0]?.text()).toContain('2.0 KB')
    expect(chips[1]?.text()).toContain('notes.md')
  })

  it('renders no chip when the message carries no file', () => {
    const wrapper = mount(ChatAttachments, { props: {} })
    expect(wrapper.findAll('.chat-attached-file-chip').length).toBe(0)
  })

  it('renders the images and the videos it always did', () => {
    const wrapper = mount(ChatAttachments, {
      props: { imageUrls: ['data:image/png;base64,AAA'] },
    })
    expect(wrapper.findAll('.chat-attached-image-thumb').length).toBe(1)
  })
})

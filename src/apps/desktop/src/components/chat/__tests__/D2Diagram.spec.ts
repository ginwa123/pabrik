/** Behavioural tests for <D2Diagram>. Nothing here touches the network: the component's contract is
 * "show the URL the server would answer, or the source when it refuses". The encoding deflates
 * through a stream, so every assertion waits for the element rather than assuming one microtask. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import D2Diagram from '../D2Diagram.vue'
import { d2SvgUrl } from '../../../helpers/d2'

const SOURCE = 'a: Alpha -> b: Beta'

const IMG = '[data-testid="chat-d2-img"]'

beforeEach(() => {
  Object.assign(navigator, {
    clipboard: { writeText: vi.fn().mockResolvedValue(undefined) },
  })
})

/** Wait for the async draw to land — the deflate runs on a stream, so a bare flushPromises races it. */
const waitForImage = (wrapper: ReturnType<typeof mount>): Promise<void> =>
  vi.waitFor(() => {
    if (!wrapper.find(IMG).exists()) throw new Error('image not drawn yet')
  })

describe('D2Diagram', () => {
  it('points an <img> at the D2 svg URL once the source is encoded', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    expect(wrapper.find(IMG).attributes('src')).toBe(await d2SvgUrl(SOURCE))
  })

  it('links the diagram out so it can be enlarged without a lightbox', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    const link = wrapper.find('[data-testid="chat-d2-open"]')
    expect(link.attributes('href')).toBe(await d2SvgUrl(SOURCE))
    expect(link.attributes('target')).toBe('_blank')
    expect(link.attributes('rel')).toContain('noopener')
  })

  it('keeps the image out of the flow until the server has answered', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    expect(wrapper.find(IMG).classes()).not.toContain('chat-d2-img--ready')
    await wrapper.find(IMG).trigger('load')
    expect(wrapper.find(IMG).classes()).toContain('chat-d2-img--ready')
  })

  it('falls back to the source, and names the host, when the render fails', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    await wrapper.find(IMG).trigger('error')
    const note = wrapper.find('[data-testid="chat-d2-error"]')
    expect(note.exists()).toBe(true)
    expect(note.text()).toContain('kroki.io')
    expect(wrapper.text()).toContain(SOURCE)
    expect(wrapper.find(IMG).exists()).toBe(false)
  })

  it('draws again when the source changes, and drops the previous failure', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    await wrapper.find(IMG).trigger('error')
    expect(wrapper.find('[data-testid="chat-d2-error"]').exists()).toBe(true)
    await wrapper.setProps({ source: 'x -> y' })
    await vi.waitFor(() => {
      if (!wrapper.find(IMG).exists()) throw new Error('image not re-drawn yet')
    })
    expect(wrapper.find('[data-testid="chat-d2-error"]').exists()).toBe(false)
  })

  it('copies the source, not the encoded URL', async () => {
    const wrapper = mount(D2Diagram, { props: { source: SOURCE } })
    await waitForImage(wrapper)
    await wrapper.find('[data-testid="chat-d2-copy"]').trigger('click')
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(SOURCE)
  })
})

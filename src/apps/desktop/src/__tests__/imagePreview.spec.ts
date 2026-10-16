/** Component tests for the <ImagePreview> overlay extracted from ChatView.vue. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'

import ImagePreview from '../components/preview/ImagePreview.vue'

const OVERLAY_CLASS = 'image-preview-overlay'
const CONTENT_CLASS = 'image-preview-content'
const CLOSE_BTN_CLASS = 'image-preview-close'
const IMG_CLASS = 'image-preview-img'

function mountPreview(src: string) {
  return mount(ImagePreview, {
    props: { src },
    attachTo: document.body,
  })
}

describe('ImagePreview', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.style.overflow = ''
    delete document.body.dataset.imagePreviewPreviousOverflow
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Force-remove any teleported overlay that survived the unmount so
    // tests don't bleed into each other through the document body.
    document.querySelectorAll(`.${OVERLAY_CLASS}`).forEach((el) => el.remove())
    document.body.style.overflow = ''
    delete document.body.dataset.imagePreviewPreviousOverflow
  })

  it('renders nothing when src is an empty string', async () => {
    wrapper = mountPreview('')
    await nextTick()
    expect(document.querySelector(`.${OVERLAY_CLASS}`)).toBeNull()
    expect(document.querySelector(`.${CONTENT_CLASS}`)).toBeNull()
  })

  it('renders the overlay, image and close button when src is set', async () => {
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    const overlay = document.querySelector(`.${OVERLAY_CLASS}`)
    expect(overlay).not.toBeNull()
    const img = document.querySelector(`.${IMG_CLASS}`) as HTMLImageElement | null
    expect(img).not.toBeNull()
    expect(img?.getAttribute('src')).toBe('https://example.com/cat.png')
    expect(document.querySelector(`.${CLOSE_BTN_CLASS}`)).not.toBeNull()
  })

  it('emits close when the overlay backdrop is clicked', async () => {
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    const overlay = document.querySelector(`.${OVERLAY_CLASS}`) as HTMLElement
    overlay.click()
    expect(wrapper!.emitted('close')).toBeTruthy()
    expect(wrapper!.emitted('close')!.length).toBe(1)
  })

  it('emits close when the close button is clicked', async () => {
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    const btn = document.querySelector(`.${CLOSE_BTN_CLASS}`) as HTMLButtonElement
    btn.click()
    expect(wrapper!.emitted('close')).toBeTruthy()
    expect(wrapper!.emitted('close')!.length).toBe(1)
  })

  it('does not emit close when clicking inside the content (image or container)', async () => {
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    const content = document.querySelector(`.${CONTENT_CLASS}`) as HTMLElement
    content.click()
    const img = document.querySelector(`.${IMG_CLASS}`) as HTMLElement
    img.click()
    expect(wrapper!.emitted('close')).toBeFalsy()
  })

  it('emits close when Escape is pressed while open', async () => {
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    const ev = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    document.dispatchEvent(ev)
    expect(wrapper!.emitted('close')).toBeTruthy()
    expect(wrapper!.emitted('close')!.length).toBe(1)
  })

  it('does not emit close on Escape when closed', async () => {
    wrapper = mountPreview('')
    await nextTick()
    const ev = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
    document.dispatchEvent(ev)
    expect(wrapper!.emitted('close')).toBeFalsy()
  })

  it('locks body scroll when open and restores it on close', async () => {
    document.body.style.overflow = 'auto'
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    expect(document.body.style.overflow).toBe('hidden')
    // Simulate the consumer clearing the src
    await wrapper.setProps({ src: '' })
    await nextTick()
    expect(document.body.style.overflow).toBe('auto')
  })

  it('unlocks body scroll on unmount even if still open', async () => {
    document.body.style.overflow = 'auto'
    wrapper = mountPreview('https://example.com/cat.png')
    await nextTick()
    expect(document.body.style.overflow).toBe('hidden')
    wrapper.unmount()
    wrapper = null
    expect(document.body.style.overflow).toBe('auto')
  })
})

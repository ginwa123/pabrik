/** ReadFile.vue — an image read shows the picture. The backend answers with
 * `{path,mime,bytes,attached_as}` and rides the bytes on the tool result's `image_url`, so the
 * card has no `content` to render and used to show `(empty)`. */
import { afterEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import ReadFile from '../ReadFile.vue'

const PNG_DATA_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

const IMAGE_PAYLOAD = {
  path: '/home/me/.agent-browser/tmp/screenshots/shot.png',
  mime: 'image/png',
  bytes: 48211,
  attached_as: 'image_url',
}

const makeWrapper = (props: {
  content: unknown
  parameters?: string
  expanded?: boolean
  imageUrls?: string[]
}) => mount(ReadFile, { props: props as never })

const imageOf = (wrapper: VueWrapper) => wrapper.find('[data-testid="read-file-image-img"]')

describe('ReadFile.vue — an image read renders the picture', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.querySelectorAll('.image-preview-overlay').forEach((el) => el.remove())
    document.body.style.overflow = ''
    delete document.body.dataset.imagePreviewPreviousOverflow
  })

  it('renders the attached picture instead of (empty)', () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD, imageUrls: [PNG_DATA_URL] })
    const img = imageOf(wrapper)
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe(PNG_DATA_URL)
    expect(wrapper.html()).not.toContain('(empty)')
  })

  it('names the mime and the byte size in the header instead of a line count', () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD, imageUrls: [PNG_DATA_URL] })
    const header = wrapper.text()
    expect(header).toContain('image/png · 47.1 KB')
    expect(header).not.toContain('0L')
  })

  it('opens itself for an image even when the parent says collapsed', () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD, imageUrls: [PNG_DATA_URL], expanded: false })
    expect(imageOf(wrapper).exists()).toBe(true)
  })

  it('keeps a user collapse of an image card', async () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD, imageUrls: [PNG_DATA_URL], expanded: false })
    expect(imageOf(wrapper).exists()).toBe(true)
    await wrapper.find('[role="button"]').trigger('click')
    expect(imageOf(wrapper).exists()).toBe(false)
  })

  it('opens the fullscreen preview when the picture is clicked', async () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD, imageUrls: [PNG_DATA_URL] })
    await imageOf(wrapper).trigger('click')
    await nextTick()
    const overlay = document.querySelector('.image-preview-overlay')
    expect(overlay).not.toBeNull()
    const fullscreen = document.querySelector('.image-preview-img') as HTMLImageElement | null
    expect(fullscreen?.getAttribute('src')).toBe(PNG_DATA_URL)
  })

  it('says the picture was not attached when the payload declares an image but no data URL arrived', () => {
    wrapper = makeWrapper({ content: IMAGE_PAYLOAD })
    expect(wrapper.find('[data-testid="read-file-image-missing"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('not attached')
    expect(wrapper.html()).not.toContain('(empty)')
  })

  it('leaves a text read unchanged', () => {
    wrapper = makeWrapper({
      content: { path: '/x.txt', content: 'alpha\nbeta', total_lines: 2, start_line: 0 },
      expanded: true,
    })
    expect(imageOf(wrapper).exists()).toBe(false)
    expect(wrapper.findAll('.rf-gutter').map((s) => s.text())).toEqual(['1', '2'])
    expect(wrapper.text()).toContain('2L')
  })
})

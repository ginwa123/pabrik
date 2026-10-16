/**  * Tests for FileInput's composer toolbar slot (V1 single-card ChatView). The parent (ChatView)
 * projects its status row into `#toolbar` so input + status render as one card. The strip renders
 * ONLY when the slot is provided — hosts without a toolbar see no extra chrome. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/file/FileInput.vue'

describe('FileInput — composer toolbar slot', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('A: renders no toolbar strip when the slot is not provided', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="composer-toolbar"]').exists()).toBe(false)
  })

  it('B: renders the strip inside the composer card when the slot is provided', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
      slots: { toolbar: '<div class="my-tool">Tool</div>' },
    })
    await flushPromises()
    const strip = wrapper.find('[data-testid="composer-toolbar"]')
    expect(strip.exists()).toBe(true)
    expect(strip.text()).toContain('Tool')
    // Inside the card — not a sibling floating row.
    expect(strip.element.closest('.composer-card')).not.toBeNull()
  })

  it('C: the Send button still renders alongside the toolbar', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
      slots: { toolbar: '<div class="my-tool">Tool</div>' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="send-message-button"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="composer-toolbar"]').exists()).toBe(true)
  })
})

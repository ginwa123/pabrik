/** FileInput `@` picker — server search + caps + abort (Task 2). */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from './FileInput.vue'
import * as api from '../../api'

vi.mock('../../api', () => ({
  API_BASE: '/api',
  searchFiles: vi.fn(),
}))

const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

interface ServerEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

function serverEntries(n: number, prefix = 'file'): ServerEntry[] {
  return Array.from({ length: n }, (_, i) => ({
    name: `${prefix}-${i}.ts`,
    path: `/home/user/src/${prefix}-${i}.ts`,
    is_directory: false,
    is_symlink: false,
  }))
}

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

/**  * Set the textarea value, park the cursor at the end, dispatch `input` so `autoResize` updates
 * `cursorPos`, then wait out BOTH debounces (150ms `@`-detect + 150ms server-search) plus promise
 * flushes. */
async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
  waitMs = 450,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  await new Promise((resolve) => setTimeout(resolve, waitMs))
  await flushPromises()
}

const fetchMock = vi.fn()

describe('FileInput — @ picker server search + caps (Task 2)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    searchFilesMock.mockReset()
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
    // Default: empty server result (picker shows "No files found").
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('typing @comp calls api.searchFiles once (no N-fetch full-tree walk)', async () => {
    searchFilesMock.mockResolvedValue({
      entries: [
        {
          name: 'components',
          path: '/home/user/src/components',
          is_directory: true,
          is_symlink: false,
        },
      ],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@comp')

    expect(searchFilesMock).toHaveBeenCalledTimes(1)
    expect(searchFilesMock).toHaveBeenCalledWith(
      '/home/user',
      'comp',
      50,
      8,
      expect.anything(),
    )
    // The old full-tree walk used raw fetch per directory — gone.
    expect(fetchMock).not.toHaveBeenCalled()
    // The server hit renders.
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)
  })

  it('render caps at 50 rows even when the server returns 200 entries', async () => {
    searchFilesMock.mockResolvedValue({ entries: serverEntries(200) })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@file')

    const buttons = wrapper.findAll('.file-picker-list button')
    expect(buttons.length).toBeLessThanOrEqual(50)
    expect(buttons.length).toBe(50)
    // Footer reports the cap vs the server total.
    expect(wrapper.find('.file-picker-list').text()).toMatch(/showing 50 of 200/i)
  })

  it('same-cwd reopen with empty query reuses the cache (no second call)', async () => {
    searchFilesMock.mockResolvedValue({
      entries: [
        {
          name: 'a.ts',
          path: '/home/user/a.ts',
          is_directory: false,
          is_symlink: false,
        },
      ],
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    // First open: `@` (empty query) hits the server once.
    await typeInTextarea(textarea, '@')
    expect(searchFilesMock).toHaveBeenCalledTimes(1)
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Close the picker.
    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()
    expect(wrapper.find('.file-picker-list').exists()).toBe(false)

    // Break the `@`-match, then reopen with the same empty query.
    await typeInTextarea(textarea, '@ ', 250)
    expect(wrapper.find('.file-picker-list').exists()).toBe(false)
    await typeInTextarea(textarea, '@')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Cache hit — still exactly one network call.
    expect(searchFilesMock).toHaveBeenCalledTimes(1)
  })

  it('stale response is discarded (late first response loses to fresh second)', async () => {
    let resolveSlow: ((v: { entries: ServerEntry[] }) => void) | null = null
    const slowPromise = new Promise<{ entries: ServerEntry[] }>((resolve) => {
      resolveSlow = resolve
    })
    searchFilesMock.mockImplementation(async (_cwd: string, q: string) => {
      if (q === 'slow') return slowPromise
      return {
        entries: [
          {
            name: 'fast.ts',
            path: '/home/user/fast.ts',
            is_directory: false,
            is_symlink: false,
          },
        ],
      }
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    // First query — request stays in flight.
    await typeInTextarea(textarea, '@slow')
    expect(searchFilesMock).toHaveBeenCalledTimes(1)

    // Second query supersedes it and resolves immediately.
    await typeInTextarea(textarea, '@fast')
    expect(searchFilesMock).toHaveBeenCalledTimes(2)
    expect(wrapper.find('.file-picker-list').text()).toContain('fast.ts')

    // The stale response lands late — it must NOT overwrite the fresh list.
    resolveSlow!({
      entries: [
        {
          name: 'slow.ts',
          path: '/home/user/slow.ts',
          is_directory: false,
          is_symlink: false,
        },
      ],
    })
    await flushPromises()
    await new Promise((r) => setTimeout(r, 50))
    await flushPromises()

    const text = wrapper.find('.file-picker-list').text()
    expect(text).toContain('fast.ts')
    expect(text).not.toContain('slow.ts')
  })
})

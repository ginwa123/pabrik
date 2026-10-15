/**
 * KanbanDescriptionEditor `@` picker — server search mirror (Task 3).
 *
 * Mirrors FileInput Task 2 (plan:
 * docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md Task 3):
 *   - Typing `@comp` calls `api.searchFiles(cwd, q, limit)` ONCE (no
 *     N-sequential-fetch full-tree walk via raw `fetch`).
 *   - snake_case `is_directory` rows are detected as dirs (the legacy
 *     raw-walk code read `entry.isDirectory` camelCase → undefined →
 *     every dir rendered as 📄 and recursion never fired).
 *   - Render caps at 50 rows even when the server returns 200 entries;
 *     footer reads `showing X of Y`.
 *   - Same-cwd reopen with an empty query reuses the per-cwd cache
 *     (no second network call).
 *   - A stale (superseded) response is discarded via the generation
 *     counter.
 */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import KanbanDescriptionEditor from './KanbanDescriptionEditor.vue'
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

async function mountEditor(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(KanbanDescriptionEditor, {
    attachTo: document.body,
    props: { modelValue: '', cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

/** Set the textarea value, park the cursor at the end, dispatch `input`
 * so `onTextareaInput` updates state, then wait out BOTH debounces
 * (150ms `@`-detect + 150ms server-search) plus promise flushes. */
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

describe('KanbanDescriptionEditor — @ picker server search (Task 3)', () => {
  beforeEach(() => {
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

  it('detects snake_case is_directory rows as dirs (📁, not 📄)', async () => {
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

    const wrapper = await mountEditor()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@comp')

    expect(searchFilesMock).toHaveBeenCalledTimes(1)
    // The old raw-walk read `entry.isDirectory` (camelCase) → undefined.
    // The port must accept `is_directory ?? isDirectory`.
    expect(wrapper.find('.file-picker-list').findAll('[data-icon="folder"]').length).toBe(1)
    expect(wrapper.find('.file-picker-list').findAll('[data-icon="file"]').length).toBe(0)
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

    const wrapper = await mountEditor()
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
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)
  })

  it('render caps at 50 rows even when the server returns 200 entries', async () => {
    searchFilesMock.mockResolvedValue({ entries: serverEntries(200) })

    const wrapper = await mountEditor()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@file')

    const buttons = wrapper.findAll('.file-picker-list button')
    expect(buttons.length).toBeLessThanOrEqual(50)
    expect(buttons.length).toBe(50)
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

    const wrapper = await mountEditor()
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

    const wrapper = await mountEditor()
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

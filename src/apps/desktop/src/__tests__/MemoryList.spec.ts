/** Tests for MemoryList.vue. Mocks the getMemories API and asserts
 * rendering states (loading, empty, populated) and the selectMemory
 * emit on row click. Mirrors the SkillsPopup / SkillList test style. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import MemoryList from '../components/tool_outputs/MemoryList.vue'

// Mock the api module so MemoryList doesn't hit the network.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    getMemories: vi.fn(),
  }
})

import { getMemories } from '../api'
const mockGetMemories = getMemories as unknown as ReturnType<typeof vi.fn>

describe('MemoryList', () => {
  let wrapper: VueWrapper | null = null

  function mountList() {
    const w = mount(MemoryList, {
      props: { selectedMemoryName: null },
      attachTo: document.body,
    })
    wrapper = w
    return w
  }

  beforeEach(() => {
    mockGetMemories.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the loading skeleton on initial mount', () => {
    mockGetMemories.mockResolvedValue({ memories: [] })
    mountList()
    // Loading state is set synchronously before the awaited call resolves.
    // The skeleton replaces the old "Loading memories..." text — it holds
    // the card list's height instead of collapsing the panel to one row.
    expect(document.body.querySelector('[data-testid="memory-list-skeleton"]')).not.toBeNull()
  })

  it('renders the empty state when the list is empty', async () => {
    mockGetMemories.mockResolvedValue({ memories: [] })
    const w = mountList()
    await w.vm.$nextTick()
    await w.vm.$nextTick()
    expect(document.body.textContent).toContain('No memories yet')
  })

  it('renders one row per memory and emits selectMemory on click', async () => {
    mockGetMemories.mockResolvedValue({
      memories: [
        { name: 'foo.md', title: 'Foo', path: '/x/foo.md', size: 13 },
        { name: 'bar.md', title: 'Bar', path: '/x/bar.md', size: 7 },
      ],
    })
    const w = mountList()
    // Let the onMounted fetch resolve + render.
    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()
    expect(document.body.textContent).toContain('Foo')
    expect(document.body.textContent).toContain('Bar')
    expect(document.body.textContent).toContain('foo.md')
    expect(document.body.textContent).toContain('bar.md')

    // Click the first memory row.
    const rows = document.querySelectorAll('.memory-list > div.space-y-2 > div')
    expect(rows.length).toBe(2)
    rows[0]!.dispatchEvent(new Event('click', { bubbles: true }))

    expect(w.emitted('selectMemory')).toBeTruthy()
    expect(w.emitted('selectMemory')![0]).toEqual(['foo.md'])
  })

  it('exposes a refresh() method that re-fetches the list', async () => {
    mockGetMemories.mockResolvedValueOnce({ memories: [] })
    const w = mountList()
    await new Promise((r) => setTimeout(r, 0))
    expect(mockGetMemories).toHaveBeenCalledTimes(1)

    // Now change the mock to a populated list, call refresh().
    mockGetMemories.mockResolvedValueOnce({
      memories: [{ name: 'new.md', title: 'New', path: '/x/new.md', size: 0 }],
    })
    // Access the exposed refresh via the wrapper's vm.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(w.vm as any).refresh()
    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()

    expect(mockGetMemories).toHaveBeenCalledTimes(2)
    expect(document.body.textContent).toContain('New')
  })
})

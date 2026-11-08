import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

vi.mock('../api', () => ({
  listWorkspaceMemories: vi.fn(),
  getWorkspaceMemory: vi.fn(),
  createWorkspaceMemory: vi.fn(),
  deleteWorkspaceMemory: vi.fn(),
}))

import WorkspaceMemoriesPanel from '../components/workspace/WorkspaceMemoriesPanel.vue'
import {
  createWorkspaceMemory,
  deleteWorkspaceMemory,
  listWorkspaceMemories,
  type WorkspaceMemory,
} from '../api'

const mockList = listWorkspaceMemories as unknown as ReturnType<typeof vi.fn>
const mockCreate = createWorkspaceMemory as unknown as ReturnType<typeof vi.fn>
const mockDelete = deleteWorkspaceMemory as unknown as ReturnType<typeof vi.fn>

function memory(overrides: Partial<WorkspaceMemory> = {}): WorkspaceMemory {
  return {
    id: 'mem_1',
    content: 'the deploy target is staging',
    tags: ['ops'],
    created_at: '2026-11-01 10:00:00',
    updated_at: '2026-11-01 10:00:00',
    ...overrides,
  }
}

function listResponse(memories: WorkspaceMemory[], total = memories.length) {
  return { workspace_id: 'ws_1', query: '', memories, total_count: total, limit: 200, offset: 0 }
}

function mountPanel(props: Record<string, unknown> = {}) {
  return mount(WorkspaceMemoriesPanel, {
    props: { workspaceId: 'ws_1', ...props },
  })
}

describe('WorkspaceMemoriesPanel', () => {
  beforeEach(() => {
    mockList.mockReset()
    mockCreate.mockReset()
    mockDelete.mockReset()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders the memories the workspace holds', async () => {
    mockList.mockResolvedValue(
      listResponse([
        memory({ id: 'mem_1', content: 'the deploy target is staging', tags: ['ops'] }),
        memory({ id: 'mem_2', content: 'cut releases on fridays', tags: ['release'] }),
      ]),
    )

    const w = mountPanel()
    await flushPromises()

    expect(mockList).toHaveBeenCalledWith('ws_1', { query: '', limit: 200 })
    const rows = w.findAll('[data-testid^="workspace-memories-row-"]')
    expect(rows).toHaveLength(2)
    expect(w.text()).toContain('the deploy target is staging')
    expect(w.text()).toContain('cut releases on fridays')
    expect(w.text()).toContain('ops')
    expect(w.find('[data-testid="workspace-memories-count"]').text()).toBe('2')
  })

  it('shows the empty state when the workspace has no memories', async () => {
    mockList.mockResolvedValue(listResponse([]))

    const w = mountPanel()
    await flushPromises()

    expect(w.find('[data-testid="empty-state"]').exists()).toBe(true)
    expect(w.text()).toContain('No memories yet')
    expect(w.findAll('[data-testid^="workspace-memories-row-"]')).toHaveLength(0)
  })

  it('shows the error and retries the same request', async () => {
    mockList.mockRejectedValueOnce(new Error('Database query failed'))
    mockList.mockResolvedValueOnce(listResponse([memory()]))

    const w = mountPanel()
    await flushPromises()

    expect(w.find('[data-testid="workspace-memories-error"]').text()).toContain(
      'Database query failed',
    )

    await w.find('[data-testid="workspace-memories-refresh"]').trigger('click')
    await flushPromises()

    expect(mockList).toHaveBeenCalledTimes(2)
    expect(w.find('[data-testid="workspace-memories-error"]').exists()).toBe(false)
    expect(w.findAll('[data-testid^="workspace-memories-row-"]')).toHaveLength(1)
  })

  it('sends the typed search term to the API after the debounce', async () => {
    vi.useFakeTimers()
    mockList.mockResolvedValue(listResponse([]))

    const w = mountPanel()
    await flushPromises()
    mockList.mockClear()

    await w.find('[data-testid="workspace-memories-search"]').setValue('deploy')
    await vi.advanceTimersByTimeAsync(300)
    await flushPromises()

    expect(mockList).toHaveBeenCalledWith('ws_1', { query: 'deploy', limit: 200 })
  })

  it('labels a filtered list by how many notes matched', async () => {
    vi.useFakeTimers()
    mockList.mockResolvedValueOnce(listResponse([memory(), memory({ id: 'mem_2' })]))
    mockList.mockResolvedValueOnce(listResponse([memory()], 1))

    const w = mountPanel()
    await flushPromises()
    expect(w.find('[data-testid="workspace-memories-count"]').text()).toBe('2')

    await w.find('[data-testid="workspace-memories-search"]').setValue('deploy')
    await vi.advanceTimersByTimeAsync(300)
    await flushPromises()

    expect(w.find('[data-testid="workspace-memories-count"]').text()).toBe('1 match')
  })

  it('expands a row to its full body and collapses it again', async () => {
    const long = 'first line\nsecond line\nthird line'
    mockList.mockResolvedValue(listResponse([memory({ content: long })]))

    const w = mountPanel()
    await flushPromises()

    const row = w.find('[data-testid="workspace-memories-row-mem_1"]')
    expect(row.text()).not.toContain('third line')

    await row.find('button').trigger('click')
    expect(row.text()).toContain('third line')

    await row.find('button').trigger('click')
    expect(row.text()).not.toContain('third line')
  })

  it('saves a new memory with the parsed tags and reloads the list', async () => {
    mockList.mockResolvedValue(listResponse([]))
    mockCreate.mockResolvedValue({ memory: memory({ id: 'mem_9', content: 'a new note' }) })

    const w = mountPanel()
    await flushPromises()

    await w.find('[data-testid="workspace-memories-new"]').trigger('click')
    await w.find('[data-testid="workspace-memories-create-body"]').setValue('a new note')
    await w.find('[data-testid="workspace-memories-create-tags"]').setValue('ops, release ,')
    await w.find('[data-testid="workspace-memories-create-save"]').trigger('click')
    await flushPromises()

    expect(mockCreate).toHaveBeenCalledWith('ws_1', 'a new note', ['ops', 'release'])
    expect(mockList).toHaveBeenCalledTimes(2)
    expect(w.find('[data-testid="workspace-memories-create-form"]').exists()).toBe(false)
  })

  it('keeps Save disabled until the body has content', async () => {
    mockList.mockResolvedValue(listResponse([]))

    const w = mountPanel()
    await flushPromises()

    await w.find('[data-testid="workspace-memories-new"]').trigger('click')
    const save = w.find('[data-testid="workspace-memories-create-save"]')
    expect(save.attributes('disabled')).toBeDefined()

    await w.find('[data-testid="workspace-memories-create-body"]').setValue('   ')
    expect(save.attributes('disabled')).toBeDefined()

    await w.find('[data-testid="workspace-memories-create-body"]').setValue('a real note')
    expect(save.attributes('disabled')).toBeUndefined()
    expect(mockCreate).not.toHaveBeenCalled()
  })

  it('deletes the expanded memory and reloads the list', async () => {
    mockList.mockResolvedValueOnce(listResponse([memory()]))
    mockList.mockResolvedValueOnce(listResponse([]))
    mockDelete.mockResolvedValue({ success: true, id: 'mem_1' })

    const w = mountPanel()
    await flushPromises()

    await w.find('[data-testid="workspace-memories-row-mem_1"] button').trigger('click')
    await w.find('[data-testid="workspace-memories-delete-mem_1"]').trigger('click')
    await flushPromises()

    expect(mockDelete).toHaveBeenCalledWith('ws_1', 'mem_1')
    expect(w.findAll('[data-testid^="workspace-memories-row-"]')).toHaveLength(0)
  })

  it('asks for a workspace instead of querying when none is given', async () => {
    const w = mountPanel({ workspaceId: '' })
    await flushPromises()

    expect(mockList).not.toHaveBeenCalled()
    expect(w.find('[data-testid="workspace-memories-no-workspace"]').exists()).toBe(true)
  })
})

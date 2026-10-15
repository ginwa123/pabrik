/**
 * Behavioural tests for PR-state coloring of the git-branch badge in
 * WorkspaceItemTaskCard.
 *
 * Contract: green = open, purple = merged, red = closed, orange =
 * plain branch — same palette as SidebarDiffPanel's prStatusStyle.
 * Bold fallback keeps the orange color (semibold) when there is no
 * cwd, no PR, or the fetch fails.
 */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import { clearPrStatusCache, invalidatePrStatus } from '@/helpers/prStatusCache'
import type { Task } from '@/stores/workspaces'

const { getPrStatusMock } = vi.hoisted(() => ({
  getPrStatusMock: vi.fn(),
}))

vi.mock('@/api', async () => {
  const actual = await vi.importActual<typeof import('@/api')>('@/api')
  return {
    ...actual,
    getPrStatus: getPrStatusMock,
  }
})

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task_1',
    name: 'Test',
    task_type: 'standard',
    ...overrides,
  }
}

function mountCard(task: Task, cwd = '') {
  return mount(WorkspaceItemTaskCard, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
      cwd,
    },
  })
}

describe('WorkspaceItemTaskCard — git branch PR status color', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    // The shared prStatusCache is module-level — reset between tests so
    // each color case fetches fresh instead of reusing a prior test's entry.
    clearPrStatusCache()
  })

  it('colors the badge green when the PR is open', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-status')).toBe('open')
    expect(badge.attributes('style') ?? '').toContain('var(--color-green)')
    expect(badge.attributes('title')).toContain('PR open — feature/x')
  })

  it('colors the badge purple when the PR is merged', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'merged', state: 'MERGED' })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.attributes('data-pr-status')).toBe('merged')
    expect(badge.attributes('style') ?? '').toContain('var(--color-violet)')
    expect(badge.attributes('title')).toContain('PR merged — feature/x')
  })

  it('colors the badge red when the PR is closed', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'closed', state: 'CLOSED' })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.attributes('data-pr-status')).toBe('closed')
    expect(badge.attributes('style') ?? '').toContain('var(--semantic-error)')
    expect(badge.attributes('title')).toContain('PR closed — feature/x')
  })

  it('falls back to bold orange when the fetch fails', async () => {
    getPrStatusMock.mockRejectedValue(new Error('no pr'))
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.attributes('data-pr-status')).toBeUndefined()
    expect(badge.attributes('style') ?? '').toContain('var(--color-orange)')
    expect(badge.attributes('title')).toContain('feature/x')
  })

  it('re-reads and recolours the badge after a merge invalidates the shared cache', async () => {
    // The reported bug: the kanban item's branch badge kept the `open` green it fetched before the
    // merge. The badge reads the shared 60s cache on mount (and on a branch/cwd change) and cannot
    // see an invalidation, so the tick from `invalidatePrStatus` is what makes it re-ask the forge.
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    expect(wrapper.find('[data-testid="task-git-branch"]').attributes('data-pr-status')).toBe(
      'open',
    )

    // The forge has now merged it — and the cache entry from before is dropped.
    getPrStatusMock.mockResolvedValue({ status: 'merged', state: 'MERGED' })
    invalidatePrStatus('/repo', 'feature/x')
    await flushPromises()

    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.attributes('data-pr-status')).toBe('merged')
    expect(badge.attributes('style') ?? '').toContain('var(--color-violet)')
    expect(badge.attributes('title')).toContain('PR merged — feature/x')
  })

  it('skips the fetch and keeps the fallback when no cwd is available', async () => {
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x' }), '')
    await flushPromises()
    expect(getPrStatusMock).not.toHaveBeenCalled()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.attributes('data-pr-status')).toBeUndefined()
    expect(badge.attributes('title')).toContain('feature/x')
  })
})

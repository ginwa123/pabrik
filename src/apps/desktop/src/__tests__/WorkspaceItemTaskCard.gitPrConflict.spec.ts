/** Conflict-only hint for the git-branch badge in WorkspaceItemTaskCard (quiet-when-clean).
 * Contract: CONFLICTING appends " · ⚠ conflicts" to the badge label, sets data-pr-conflict, and
 * extends the tooltip with "merge conflicts". */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import { clearPrStatusCache } from '@/helpers/prStatusCache'
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

describe('WorkspaceItemTaskCard — git branch conflict hint', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    clearPrStatusCache()
  })

  it('appends the conflict suffix when the PR is CONFLICTING', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
    })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('feature/x · ⚠ conflicts')
    expect(badge.attributes('data-pr-conflict')).toBe('true')
    expect(badge.attributes('data-pr-status')).toBe('open')
    expect(badge.attributes('title')).toContain('PR open — merge conflicts — feature/x')
  })

  it('stays quiet (bare branch, no attr) when the PR is mergeable', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
    })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.text()).not.toContain('⚠')
    expect(badge.attributes('data-pr-conflict')).toBeUndefined()
    expect(badge.attributes('title')).toContain('PR open — feature/x')
  })

  it('stays quiet when mergeable is unknown', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    const wrapper = mountCard(makeTask({ git_branch: 'feature/x', cwd: '/repo' }), '/repo')
    await flushPromises()
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.text()).not.toContain('⚠')
    expect(badge.attributes('data-pr-conflict')).toBeUndefined()
  })
})

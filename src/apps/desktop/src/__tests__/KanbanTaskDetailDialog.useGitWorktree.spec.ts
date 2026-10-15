/** Tests for the "Use git worktree" toggle in KanbanTaskDetailDialog
 * (create mode) — plan:
 * docs/superpowers/plans/2026-09-11-kanban-create-task-message-format-worktree-toggle.md
 *   Task 2
 * Mount pattern: same as KanbanTaskDetailDialog.runAgent.spec.ts.
 * <Teleport to="body">, so use `attachTo: document.body` +
 * `document.querySelector` (NOT `wrapper.find`). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import * as api from '@/api'
import type { Task } from '@/stores/workspaces'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — Use git worktree toggle', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  function setName(value: string) {
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  function setWorktreeToggle(checked: boolean) {
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-use-git-worktree-toggle"]',
    )
    if (!toggle) throw new Error('worktree toggle missing')
    toggle.checked = checked
    toggle.dispatchEvent(new Event('change', { bubbles: true }))
  }

  function setWorktreePath(value: string) {
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-use-git-worktree-path"]',
    )
    if (!input) throw new Error('worktree path input missing')
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
  }

  it('renders the worktree toggle in create mode, default OFF', async () => {
    mountDialog()
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-use-git-worktree-toggle"]',
    )
    expect(toggle).not.toBeNull()
    expect(toggle!.checked).toBe(false)
  })

  it('does NOT render the worktree toggle in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-use-git-worktree-toggle"]'),
    ).toBeNull()
  })

  it('create-and-run emit carries useGitWorktree: false by default', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { useGitWorktree: boolean }).useGitWorktree).toBe(false)
  })

  it('flipping the toggle on flows into the create-and-run emit', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { useGitWorktree: boolean }).useGitWorktree).toBe(true)
  })

  it('flipping the toggle on flows into the plain create emit', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { useGitWorktree: boolean }).useGitWorktree).toBe(true)
  })

  it('hides the path input when the toggle is OFF', async () => {
    mountDialog()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-use-git-worktree-path"]'),
    ).toBeNull()
  })

  it('prefills the path under ~/.config/pabrik/.worktrees when toggled on', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-use-git-worktree-path"]',
    )
    expect(input).not.toBeNull()
    expect(input!.value).toContain('.config/pabrik/.worktrees')
    expect(input!.value).toContain('my-task')
    expect(input!.value).toMatch(/my-task-\d+$/)
  })

  it('prefills an absolute path when home is known (Option A canonical root)', async () => {
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/home/testuser',
      absolute: '/home/testuser',
      home: '/home/testuser',
      entries: [],
    })
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-use-git-worktree-path"]',
    )
    expect(input).not.toBeNull()
    expect(input!.value).toMatch(/^\/home\/testuser\/\.config\/pabrik\/\.worktrees\/my-task-\d+$/)
  })

  it('expands a ~/ path to absolute on create-and-run emit', async () => {
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/home/testuser',
      absolute: '/home/testuser',
      home: '/home/testuser',
      entries: [],
    })
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    setWorktreePath('~/.config/pabrik/.worktrees/custom')
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { worktreePath: string }).worktreePath).toBe(
      '/home/testuser/.config/pabrik/.worktrees/custom',
    )
  })

  it('custom path flows into the create-and-run emit', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    setWorktreePath('/tmp/custom-wt/my-task')
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { worktreePath: string }).worktreePath).toBe(
      '/tmp/custom-wt/my-task',
    )
  })

  it('custom path flows into the plain create emit', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    setWorktreePath('/tmp/custom-wt/my-task')
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    expect((emitted![0]![0] as { worktreePath: string }).worktreePath).toBe(
      '/tmp/custom-wt/my-task',
    )
  })

  // ─── Base branch (the `Base:` line) ───────────────────────────────────

  function findItemByText(text: string): HTMLButtonElement | null {
    return (
      findAllInDom<HTMLButtonElement>(
        '[data-testid="git-base-branch-select-item"]',
      ).find((el) => (el.textContent ?? '').includes(text)) ?? null
    )
  }

  async function openBaseBranchPicker() {
    findInDom<HTMLButtonElement>(
      '[data-testid="git-base-branch-select-trigger"]',
    )?.click()
    await flushPromises()
  }

  it('renders the base-branch picker only while the worktree toggle is ON', async () => {
    mountDialog()
    await flushPromises()
    expect(
      findInDom('[data-testid="git-base-branch-select-trigger"]'),
    ).toBeNull()

    setWorktreeToggle(true)
    await flushPromises()
    expect(
      findInDom('[data-testid="git-base-branch-select-trigger"]'),
    ).not.toBeNull()
    // Not the same as the path input — both live in the worktree block.
    expect(
      findInDom('[data-testid="kanban-task-detail-use-git-worktree-path"]'),
    ).not.toBeNull()
  })

  it('create-and-run emit carries an empty worktreeBaseBranch by default', async () => {
    mountDialog()
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect(
      (emitted![0]![0] as { worktreeBaseBranch: string }).worktreeBaseBranch,
    ).toBe('')
  })

  it('a picked base branch flows into the create-and-run emit', async () => {
    vi.spyOn(api, 'listGitBranches').mockResolvedValue({
      is_git_repo: true,
      current_branch: 'main',
      branches: [
        { name: 'origin/main', is_remote: true, is_current: false, is_default: true },
        { name: 'main', is_remote: false, is_current: true, is_default: false },
      ],
    })
    mountDialog({ cwd: '/home/you/repo' })
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()

    await openBaseBranchPicker()
    findItemByText('origin/main')?.click()
    await flushPromises()

    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()

    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect(
      (emitted![0]![0] as { worktreeBaseBranch: string }).worktreeBaseBranch,
    ).toBe('origin/main')
  })

  it('a picked base branch also flows into the plain create emit', async () => {
    vi.spyOn(api, 'listGitBranches').mockResolvedValue({
      is_git_repo: true,
      current_branch: 'main',
      branches: [
        { name: 'origin/main', is_remote: true, is_current: false, is_default: true },
      ],
    })
    mountDialog({ cwd: '/home/you/repo' })
    await flushPromises()
    setName('My task')
    await flushPromises()
    setWorktreeToggle(true)
    await flushPromises()

    await openBaseBranchPicker()
    findItemByText('origin/main')?.click()
    await flushPromises()

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')?.click()
    await flushPromises()

    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    expect(
      (emitted![0]![0] as { worktreeBaseBranch: string }).worktreeBaseBranch,
    ).toBe('origin/main')
  })

  it('the picked base branch is reset when the dialog reopens', async () => {
    vi.spyOn(api, 'listGitBranches').mockResolvedValue({
      is_git_repo: true,
      current_branch: 'main',
      branches: [
        { name: 'origin/main', is_remote: true, is_current: false, is_default: true },
      ],
    })
    mountDialog({ cwd: '/home/you/repo' })
    await flushPromises()
    setName('My task')
    setWorktreeToggle(true)
    await flushPromises()
    await openBaseBranchPicker()
    findItemByText('origin/main')?.click()
    await flushPromises()

    // Close + reopen (the watcher resets create-mode state on open).
    await wrapper!.setProps({ show: false })
    await flushPromises()
    await wrapper!.setProps({ show: true })
    await flushPromises()

    // The name was reset too, so re-enter it before the commit buttons
    // become clickable again.
    setName('My task')
    setWorktreeToggle(true)
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(
      (emitted![0]![0] as { worktreeBaseBranch: string }).worktreeBaseBranch,
    ).toBe('')
  })
})

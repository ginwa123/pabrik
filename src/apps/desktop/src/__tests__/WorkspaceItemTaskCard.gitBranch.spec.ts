/** Behavioural tests for the git-branch badge in WorkspaceItemTaskCard. */
import { describe, expect, it, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import type { Task } from '@/stores/workspaces'

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task_1',
    name: 'Test',
    task_type: 'standard',
    ...overrides,
  }
}

describe('WorkspaceItemTaskCard — git branch badge', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders the badge when task.git_branch is set', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ git_branch: 'feature/x' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('feature/x')
    // The branch text is wrapped in its own <span> so the SVG can
    // stay aria-hidden. Lock the inner-span content to be the
    // branch name verbatim (the SVG does NOT count as text).
    expect(badge.text()).toBe('feature/x')
  })

  it('hides the badge when task.git_branch is empty string', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ git_branch: '' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-git-branch"]').exists()).toBe(false)
  })

  it('hides the badge when task.git_branch is null', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ git_branch: null }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-git-branch"]').exists()).toBe(false)
  })

  it('hides the badge when task.git_branch is undefined', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({}),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-git-branch"]').exists()).toBe(false)
  })

  it('renders a fork/branch SVG icon inside the badge', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ git_branch: 'main' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    // Lock in the icon — the GitHub-style fork/branch SVG. If anyone
    // replaces it with a different icon (e.g. a generic branch dot),
    // this test fails.
    const svg = badge.find('svg')
    expect(svg.exists()).toBe(true)
    // The path "M6 3v12M18 9..." is the distinctive fork/branch shape.
    expect(svg.html()).toContain('M6 3v12')
    expect(svg.html()).toContain('M18 9a3 3 0 100-6')
  })

  it('applies truncate class to handle long branch names', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({
          git_branch: 'worktree/very-long-feature-branch-name-that-overflows',
        }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.exists()).toBe(true)
    expect(badge.classes()).toContain('truncate')
    expect(badge.classes().some((c) => c.includes('max-w-'))).toBe(true)
  })

  it('sets the title attribute to the full branch name (for hover tooltip)', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({
          git_branch: 'worktree/very-long-feature-branch-name',
        }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const badge = wrapper.find('[data-testid="task-git-branch"]')
    expect(badge.attributes('title')).toContain(
      'worktree/very-long-feature-branch-name',
    )
  })

  it('renders the branch badge alongside the type badge in the meta row', () => {
    // Memory tasks have a "memory" type label AND now a branch badge.
    // Both should be in the same data-testid="task-meta" row.
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({
          task_type: 'memory',
          git_branch: 'main',
          is_pinned: false,
        }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const metaRow = wrapper.find('[data-testid="task-meta"]')
    expect(metaRow.exists()).toBe(true)
    expect(metaRow.find('[data-testid="task-meta-type-memory"]').exists()).toBe(
      true,
    )
    expect(metaRow.find('[data-testid="task-git-branch"]').exists()).toBe(true)
  })

  it('renders the badge alone (no type badge) when only git_branch is set', () => {
    // Standard task with a branch — no routine/memory type badge,
    // but the meta row should still render because the branch badge
    // is present.
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({
          task_type: 'standard',
          git_branch: 'main',
        }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const metaRow = wrapper.find('[data-testid="task-meta"]')
    expect(metaRow.exists()).toBe(true)
    // No type badge for standard tasks.
    expect(
      wrapper.find('[data-testid="task-meta-type-routine"]').exists(),
    ).toBe(false)
    expect(wrapper.find('[data-testid="task-git-branch"]').exists()).toBe(true)
  })
})
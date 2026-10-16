/** Tests for the new "Create worktree" item in WorktreeMenu's no-worktree branch. The other menu
 * items are tested in worktreeMenu.spec.ts (regression tests for the v1.0 WorktreeMenu). */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import WorktreeMenu from '../components/workspace/WorktreeMenu.vue'

function mountMenu(hasWorktree: boolean) {
  return mount(WorktreeMenu, {
    props: { hasWorktree, branch: 'main', status: 'clean' },
  })
}

describe('WorktreeMenu — Create worktree item (hasWorktree=false)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders "Create worktree" with the correct data-testid', () => {
    wrapper = mountMenu(false)
    expect(wrapper.find('[data-testid="worktree-menu-create-worktree"]').exists()).toBe(true)
  })

  it('renders the 3 no-worktree items in the correct order: Create, Open, Refresh', () => {
    wrapper = mountMenu(false)
    const buttons = wrapper.findAll('button[data-testid^="worktree-menu-"]')
    expect(buttons.length).toBe(3)
    expect(buttons[0]!.attributes('data-testid')).toBe('worktree-menu-create-worktree')
    expect(buttons[1]!.attributes('data-testid')).toBe('worktree-menu-view-folder')
    expect(buttons[2]!.attributes('data-testid')).toBe('worktree-menu-refresh')
  })

  it('clicking "Create worktree" emits create-worktree and close', async () => {
    wrapper = mountMenu(false)
    await wrapper.find('[data-testid="worktree-menu-create-worktree"]').trigger('click')
    expect(wrapper.emitted('create-worktree')).toBeTruthy()
    expect(wrapper.emitted('create-worktree')!.length).toBe(1)
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('close')!.length).toBe(1)
  })
})

describe('WorktreeMenu — Create worktree is hidden when hasWorktree=true', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('does NOT render the create-worktree item when a worktree is already bound', () => {
    wrapper = mountMenu(true)
    expect(wrapper.find('[data-testid="worktree-menu-create-worktree"]').exists()).toBe(false)
  })
})

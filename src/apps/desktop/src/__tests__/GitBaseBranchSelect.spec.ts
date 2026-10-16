/** Tests for GitBaseBranchSelect — the searchable base-branch dropdown in the kanban "New task"
 * dialog's git-worktree block. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'

import GitBaseBranchSelect from '@/components/kanban/GitBaseBranchSelect.vue'
import * as api from '@/api'

const BRANCHES: api.GitBranchEntry[] = [
  { name: 'origin/main', is_remote: true, is_current: false, is_default: true },
  { name: 'origin/develop', is_remote: true, is_current: false, is_default: false },
  { name: 'main', is_remote: false, is_current: true, is_default: false },
  { name: 'worktree/foo', is_remote: false, is_current: false, is_default: false },
]

function mockBranches(branches: api.GitBranchEntry[] = BRANCHES) {
  return vi.spyOn(api, 'listGitBranches').mockResolvedValue({
    is_git_repo: true,
    current_branch: 'main',
    branches,
  })
}

describe('GitBaseBranchSelect', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    vi.restoreAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  function mountSelect(propsOverride: Record<string, unknown> = {}) {
    wrapper = mount(GitBaseBranchSelect, {
      attachTo: document.body,
      props: {
        modelValue: '',
        repoPath: '/home/you/repo',
        ...propsOverride,
      },
    })
    return wrapper
  }

  async function openDropdown() {
    await wrapper!.find('[data-testid="git-base-branch-select-trigger"]').trigger('click')
    await flushPromises()
  }

  it('shows "HEAD (default)" when no base is selected', () => {
    mockBranches()
    mountSelect()
    const trigger = wrapper!.find('[data-testid="git-base-branch-select-trigger"]')
    expect(trigger.text()).toContain('Base branch')
    expect(trigger.text()).toContain('HEAD (default)')
  })

  it('shows the selected ref on the trigger', () => {
    mockBranches()
    mountSelect({ modelValue: 'origin/main' })
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-trigger"]').text(),
    ).toContain('origin/main')
  })

  it('does not render the dropdown until the trigger is clicked', () => {
    mockBranches()
    mountSelect()
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-dropdown"]').exists(),
    ).toBe(false)
  })

  it('lazily loads and lists branches on first open', async () => {
    const spy = mockBranches()
    mountSelect()
    expect(spy).not.toHaveBeenCalled()
    await openDropdown()

    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenCalledWith('/home/you/repo')
    const items = wrapper!.findAll('[data-testid="git-base-branch-select-item"]')
    expect(items.map((i) => i.text())).toEqual([
      'origin/main · default',
      'origin/develop',
      'main · current',
      'worktree/foo',
    ])
  })

  it('does NOT refetch when the dropdown is reopened for the same repo', async () => {
    const spy = mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!.find('[data-testid="git-base-branch-select-trigger"]').trigger('click')
    await openDropdown()
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('filters the list by the search query (case-insensitive)', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!.find('[data-testid="git-base-branch-select-search"]').setValue('ORIGIN/DEV')
    const items = wrapper!.findAll('[data-testid="git-base-branch-select-item"]')
    expect(items.map((i) => i.text())).toEqual(['origin/develop'])
  })

  it('emits the clicked ref and closes', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!.findAll('[data-testid="git-base-branch-select-item"]')[0]!.trigger('click')
    await flushPromises()

    expect(wrapper!.emitted('update:modelValue')).toEqual([['origin/main']])
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-dropdown"]').exists(),
    ).toBe(false)
  })

  it('"Follow HEAD" clears the selection to the empty string', async () => {
    mockBranches()
    mountSelect({ modelValue: 'origin/main' })
    await openDropdown()
    await wrapper!.find('[data-testid="git-base-branch-select-clear"]').trigger('click')
    await flushPromises()
    expect(wrapper!.emitted('update:modelValue')).toEqual([['']])
  })

  it('offers a typed-but-unlisted ref and emits it on click', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!.find('[data-testid="git-base-branch-select-search"]').setValue('origin/not-fetched')

    const custom = wrapper!.find('[data-testid="git-base-branch-select-custom"]')
    expect(custom.exists()).toBe(true)
    expect(custom.text()).toContain('origin/not-fetched')

    await custom.trigger('click')
    await flushPromises()
    expect(wrapper!.emitted('update:modelValue')).toEqual([['origin/not-fetched']])
  })

  it('does not offer the custom row for an exactly listed ref', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!.find('[data-testid="git-base-branch-select-search"]').setValue('origin/main')
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-custom"]').exists(),
    ).toBe(false)
  })

  it('Enter commits the typed ref when nothing is highlighted', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    const search = wrapper!.find('[data-testid="git-base-branch-select-search"]')
    await search.setValue('origin/typed-by-hand')
    await search.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(wrapper!.emitted('update:modelValue')).toEqual([['origin/typed-by-hand']])
  })

  it('ArrowDown + Enter commits the first match', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    const search = wrapper!.find('[data-testid="git-base-branch-select-search"]')
    await search.trigger('keydown', { key: 'ArrowDown' })
    await search.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(wrapper!.emitted('update:modelValue')).toEqual([['origin/main']])
  })

  it('Escape closes the dropdown without emitting', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!
      .find('[data-testid="git-base-branch-select-search"]')
      .trigger('keydown', { key: 'Escape' })
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-dropdown"]').exists(),
    ).toBe(false)
    expect(wrapper!.emitted('update:modelValue')).toBeFalsy()
  })

  it('closes on a mousedown outside the component', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    document.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await flushPromises()
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-dropdown"]').exists(),
    ).toBe(false)
  })

  it('does not fetch and shows the empty state when repoPath is blank', async () => {
    const spy = mockBranches()
    mountSelect({ repoPath: '' })
    await openDropdown()
    expect(spy).not.toHaveBeenCalled()
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-empty"]').text(),
    ).toContain('No branches listed')
  })

  it('shows a no-match message when the search excludes every branch', async () => {
    mockBranches()
    mountSelect()
    await openDropdown()
    await wrapper!
      .find('[data-testid="git-base-branch-select-search"]')
      .setValue('zzz-nonexistent')
    // The custom row is offered, and the no-match copy explains the list.
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-empty"]').text(),
    ).toContain('No branch matches that search')
  })

  it('survives a backend failure with an empty list (never blocks the form)', async () => {
    // listGitBranches already swallows errors and resolves the empty
    // response — model that contract here.
    vi.spyOn(api, 'listGitBranches').mockResolvedValue({
      is_git_repo: false,
      current_branch: '',
      branches: [],
    })
    mountSelect()
    await openDropdown()
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-empty"]').exists(),
    ).toBe(true)
    expect(
      wrapper!.find('[data-testid="git-base-branch-select-item"]').exists(),
    ).toBe(false)
  })

  it('disables the trigger when `disabled` is set', () => {
    mockBranches()
    mountSelect({ disabled: true })
    const trigger = wrapper!.find<HTMLButtonElement>(
      '[data-testid="git-base-branch-select-trigger"]',
    )
    expect(trigger.attributes('disabled')).toBeDefined()
  })
})

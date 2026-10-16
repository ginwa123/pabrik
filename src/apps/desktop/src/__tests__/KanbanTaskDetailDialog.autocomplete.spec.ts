/** Behavioural tests for KanbanTaskDetailDialog — tag autocomplete wiring (Task 2.7 of the
 * kanban-task-tags-autocomplete plan). Plan:
 * docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md Chunk 2 / Task 2.7 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task, KanbanColumn } from '@/stores/workspaces'
import * as api from '../api'

const TASK_WITH_TAGS: Task = {
  id: 'task_test_1',
  name: 'Original name',
  description: '',
  task_type: 'standard',
  tags: ['bug'],
}

// The dialog reads the parent kanban's workspace_item_id from the `column` prop (Task itself
// doesn't carry workspace_item_id). All `mountDialog()` calls below pass this so the composable has
// a valid item id to fetch suggestions for.
const COLUMN: KanbanColumn = {
  id: 'col_x',
  workspace_item_id: 'item_x',
  name: 'todo',
  position: 0,
  created_at: '2026-01-01 00:00:00',
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — tag autocomplete wiring', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.resetAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(
    task: Task | null = TASK_WITH_TAGS,
    overrides: Record<string, unknown> = {},
  ) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        task,
        column: COLUMN,
        workspaceId: 'ws_x',
        ...overrides,
      },
    })
    return wrapper
  }

  it('mounts the tag suggestions composable with the dialog task item id (Task 2.7 wiring)', async () => {
    const spy = vi
      .spyOn(api, 'getKanbanTagSuggestions')
      .mockResolvedValue({
        tags: [
          { name: 'bug', count: 3, last_used_at: null },
          { name: 'urgent', count: 1, last_used_at: null },
        ],
        has_more: false,
      })

    mountDialog(TASK_WITH_TAGS)
    await flushPromises()
    await flushPromises()
    // The dialog's watcher fires ensureLoaded() when show=true and a
    // task + workspaceId are present. The composable passes the ids
    // through to getKanbanTagSuggestions.
    expect(spy).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
  })

  it('filters out tags already on the current task from the suggestions passed to KanbanTagsInput', async () => {
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [
        { name: 'bug', count: 3, last_used_at: null },
        { name: 'urgent', count: 1, last_used_at: null },
        { name: 'frontend', count: 1, last_used_at: null },
      ],
      has_more: false,
    })

    // Task already has 'bug' as a chip. The dialog should NOT pass
    // 'bug' into the input's :suggestions binding.
    mountDialog(TASK_WITH_TAGS)
    await flushPromises()
    await flushPromises()

    // Open the input so the dropdown renders + suggestions mount.
    const field = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-tags-field"]')
    if (!field) throw new Error('tags field not found')
    field.focus()
    field.dispatchEvent(new Event('focus', { bubbles: true }))
    await flushPromises()

    const suggestionsContainer = findInDom(
      '[data-testid="kanban-task-detail-tags-suggestions"]',
    )
    expect(suggestionsContainer).not.toBeNull()
    const bugRow = findInDom(
      '[data-testid="kanban-task-detail-tags-suggestion-bug"]',
    )
    const urgentRow = findInDom(
      '[data-testid="kanban-task-detail-tags-suggestion-urgent"]',
    )
    const frontendRow = findInDom(
      '[data-testid="kanban-task-detail-tags-suggestion-frontend"]',
    )
    expect(bugRow).toBeNull() // already a chip — filtered out
    expect(urgentRow).not.toBeNull()
    expect(frontendRow).not.toBeNull()
  })

  it('fetches in create mode when the column prop is present (so the new task can pick from existing tags)', async () => {
    // Plan: docs/superpowers/plans/2026-08-06-kanban-tags-autocomplete-in-create-mode.md The
    // previous test ("does NOT fetch in create mode") locked in a bug: users opening the "+ Add
    // task" dialog could not see the kanban's existing tags in the dropdown.
    const spy = vi
      .spyOn(api, 'getKanbanTagSuggestions')
      .mockResolvedValue({
        tags: [{ name: 'kanban', count: 5, last_used_at: null }],
        has_more: false,
      })

    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: COLUMN,            // provides workspace_item_id 'item_x'
        workspaceId: 'ws_x',
      },
    })
    await flushPromises()
    await flushPromises()
    expect(spy).toHaveBeenCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })
  })

  it('renders the existing-tag dropdown in create mode so the user can one-click pick a tag', async () => {
    // Plan: docs/superpowers/plans/2026-08-06-kanban-tags-autocomplete-in-create-mode.md Regression
    // guard for the user-reported symptom: "when create a task, the auto tags not trigger".
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [
        { name: 'kanban', count: 5, last_used_at: null },
        { name: 'git', count: 3, last_used_at: null },
        { name: 'git_worktree', count: 2, last_used_at: null },
      ],
      has_more: false,
    })

    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: COLUMN,
        workspaceId: 'ws_x',
      },
    })
    await flushPromises()
    await flushPromises()

    const field = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-tags-field"]',
    )
    if (!field) throw new Error('tags field not found')
    field.focus()
    field.dispatchEvent(new Event('focus', { bubbles: true }))
    await flushPromises()

    // All three existing kanban tags should appear as suggestions. None are
    // on the task yet (it's brand-new), so the exclude set is empty.
    expect(
      findInDom('[data-testid="kanban-task-detail-create-tags-suggestion-kanban"]'),
    ).not.toBeNull()
    expect(
      findInDom('[data-testid="kanban-task-detail-create-tags-suggestion-git"]'),
    ).not.toBeNull()
    expect(
      findInDom(
        '[data-testid="kanban-task-detail-create-tags-suggestion-git_worktree"]',
      ),
    ).not.toBeNull()
  })

  it('clicking a suggestion in create mode adds the chip (one-click pick)', async () => {
    // Plan: docs/superpowers/plans/2026-08-06-kanban-tags-autocomplete-in-create-mode.md
    // End-to-end of the user request: open "+ Add task", focus tags input,
    // click an existing tag in the dropdown, see the chip appear.
    vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [
        { name: 'kanban', count: 5, last_used_at: null },
        { name: 'urgent', count: 1, last_used_at: null },
      ],
      has_more: false,
    })

    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: COLUMN,
        workspaceId: 'ws_x',
      },
    })
    await flushPromises()
    await flushPromises()

    const field = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-tags-field"]',
    )
    if (!field) throw new Error('tags field not found')
    field.focus()
    field.dispatchEvent(new Event('focus', { bubbles: true }))
    await flushPromises()

    const kanbanSuggestion = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-create-tags-suggestion-kanban"]',
    )
    if (!kanbanSuggestion) throw new Error('kanban suggestion row not found')
    // KanbanTagsInput uses `@mousedown.prevent` (not @click) so the blur
    // doesn't dismiss the dropdown before commit fires.
    kanbanSuggestion.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await flushPromises()

    const chip = findInDom(
      '[data-testid="kanban-task-detail-create-tags-chip-kanban"]',
    )
    expect(chip).not.toBeNull()
  })

  it('resets the composable on dialog close + reopen so a fresh fetch is triggered', async () => {
    const spy = vi.spyOn(api, 'getKanbanTagSuggestions').mockResolvedValue({
      tags: [],
      has_more: false,
    })

    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        task: TASK_WITH_TAGS,
        column: COLUMN,  // required so the composable has a valid item_id (graceful degradation skips otherwise)
        workspaceId: 'ws_x',
      },
    })
    await flushPromises()
    await flushPromises()
    const callsAfterOpen = spy.mock.calls.length

    // Toggle show false then true again — the watcher should reset
    // the composable and trigger ensureLoaded again.
    await wrapper!.setProps({ show: false })
    await flushPromises()
    await wrapper!.setProps({ show: true })
    await flushPromises()
    await flushPromises()

    expect(spy.mock.calls.length).toBeGreaterThan(callsAfterOpen)
  })

  it('forwards the composable loadNextPage to the input via onLoadMore', async () => {
    const spy = vi.spyOn(api, 'getKanbanTagSuggestions')
    spy.mockResolvedValueOnce({
      tags: [{ name: 'a', count: 1, last_used_at: null }],
      has_more: true,
    })
    spy.mockResolvedValueOnce({
      tags: [{ name: 'b', count: 1, last_used_at: null }],
      has_more: false,
    })

    mountDialog(TASK_WITH_TAGS)
    await flushPromises()
    await flushPromises()
    // First page fetched.
    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy).toHaveBeenLastCalledWith('ws_x', 'item_x', { limit: 8, offset: 0 })

    // The wiring proof: the KanbanTagsInput child component receives
    // the composable's loadNextPage function as its `onLoadMore` prop.
    // Calling that prop triggers a second fetch at offset=8.
    const tagsInput = wrapper!.findComponent({ name: 'KanbanTagsInput' })
    expect(tagsInput.exists()).toBe(true)
    const onLoadMore = tagsInput.props('onLoadMore')
    expect(typeof onLoadMore).toBe('function')
    await (onLoadMore as () => Promise<void>)()
    await flushPromises()
    expect(spy).toHaveBeenCalledTimes(2)
    expect(spy).toHaveBeenLastCalledWith('ws_x', 'item_x', { limit: 8, offset: 8 })
  })
})
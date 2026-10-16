/** Tests for KanbanList.vue — the tool_output component that renders the XML response from the
 * `kanban_list` agent tool. The component is purely presentational (no API calls), so no mocks are
 * needed. Mirrors the SetGitWorktree / SearchSkills tool_output style. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import KanbanList from '../components/tool_outputs/KanbanList.vue'

const SUCCESS_XML = {
  workspace_id: 'ws_1779002584293_e52cd134532e1f00',
  item_id: 'item_1782442554104741821',
  columns: [
    { id: 'col_1782442554112968570', name: 'todo', position: 0, task_count: 2 },
    { id: 'col_1782442554114534970', name: 'in progress', position: 1, task_count: 3 },
    { id: 'col_1782442554115179957', name: 'done', position: 2, task_count: 0 },
  ],
  tasks: [
    { id: 'task_1782319202279', name: 'squash-merge-pr-38-to-main', column_id: 'col_1782442554112968570', column_name: 'todo', position: 0 },
    { id: 'task_1782551466784', name: 'stream-idle-timeout-increase', column_id: 'col_1782442554112968570', column_name: 'todo', position: 1 },
    { id: 'task_1782549179378', name: 'implement-kanban-status-prompt', column_id: 'col_1782442554114534970', column_name: 'in progress', position: 0 },
    { id: 'task_1782568979811', name: 'tool-component-output', column_id: 'col_1782442554114534970', column_name: 'in progress', position: 1 },
    { id: 'task_1782569378361', name: 'kanban-sse-auto-move', column_id: 'col_1782442554114534970', column_name: 'in progress', position: 2 },
    { id: 'task_orphan_42', name: 'orphan-task-with-no-column', column_id: null, column_name: null, position: 0 },
  ],
  total_count: 6,
  limit: 50,
  offset: 0,
  has_more: false,
  hint: null,
}

const EMPTY_BOARD_XML = {
  workspace_id: 'ws_1779002584293_e52cd134532e1f00',
  item_id: 'item_empty_42',
  columns: [],
  tasks: [],
  total_count: 0,
  limit: 50,
  offset: 0,
  has_more: false,
  hint: "This kanban item has no columns (0 columns). The user may have deleted all columns, or the kanban was just created and columns haven't been seeded yet.",
}

const ERROR_XML = {
  error: "item_id 'item_9999' matches no workspace_item (or the item isn't a kanban). Verify the id from the Workspace Context listing.",
}

const MISSING_FIELD_ERROR = { error: 'Missing required field: workspace_id' }

const NO_TASKS_BUT_HAS_COLUMNS = {
  workspace_id: 'ws_1779002584293_e52cd134532e1f00',
  item_id: 'item_empty_tasks',
  columns: [{ id: 'col_1', name: 'todo', position: 0, task_count: 0 }],
  tasks: [],
  total_count: 0,
  limit: 50,
  offset: 0,
  has_more: false,
  hint: null,
}

describe('KanbanList', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the tool name "kanban_list" in the header', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('kanban_list')
  })

  it('shows the column + task counts in the collapsed header on success', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('3 columns')
    expect(wrapper.text()).toContain('6 tasks')
  })

  it('uses singular forms correctly (1 column, 1 task)', () => {
    const oneEach = {
      workspace_id: 'ws_1',
      item_id: 'item_1',
      columns: [{ id: 'col_1', name: 'todo', position: 0, task_count: 1 }],
      tasks: [{ id: 'task_1', name: 'only task', column_id: 'col_1', column_name: 'todo', position: 0 }],
      total_count: 1,
      limit: 50,
      offset: 0,
      has_more: false,
      hint: null,
    }
    wrapper = mount(KanbanList, {
      props: { content: oneEach, expanded: false },
    })
    expect(wrapper.text()).toContain('1 column')
    expect(wrapper.text()).not.toContain('1 columns')
    expect(wrapper.text()).toContain('1 task')
    expect(wrapper.text()).not.toContain('1 tasks')
  })

  it('shows the ✓ status indicator on success', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('shows the ✗ status indicator on error', () => {
    wrapper = mount(KanbanList, {
      props: { content: ERROR_XML },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('expands to show the columns + tasks lists when clicked', async () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    // Collapsed: section headers not visible
    expect(wrapper.text()).not.toContain('Columns (3)')

    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.text()).toContain('Columns (3)')
    expect(wrapper.text()).toContain('Tasks (6)')
  })

  it('renders each column name and its task count', async () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    const text = wrapper.text()
    expect(text).toContain('todo')
    expect(text).toContain('in progress')
    expect(text).toContain('done')
    // The task_count badges
    expect(text).toContain('2')
    expect(text).toContain('3')
    // Position labels
    expect(text).toContain('#0')
    expect(text).toContain('#1')
    expect(text).toContain('#2')
  })

  it('renders each task name and column label in the task list', async () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    const text = wrapper.text()
    expect(text).toContain('squash-merge-pr-38-to-main')
    expect(text).toContain('implement-kanban-status-prompt')
    expect(text).toContain('tool-component-output')
    expect(text).toContain('orphan-task-with-no-column')
  })

  it('separates unassigned tasks into their own subsection', async () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    expect(wrapper.text()).toContain('Unassigned (1)')
    // The orphan task should appear under the Unassigned section
    expect(wrapper.text()).toContain('unassigned')
  })

  it('shows the empty-board hint instead of an error when the kanban has 0 columns', async () => {
    wrapper = mount(KanbanList, {
      props: { content: EMPTY_BOARD_XML, expanded: true },
    })
    expect(wrapper.text()).toContain('✓') // success status, not error
    expect(wrapper.text()).not.toContain('✗')
    expect(wrapper.text()).toContain('Hint:')
    expect(wrapper.text()).toContain('This kanban item has no columns')
    // The "No columns on this board." text should also appear
    expect(wrapper.text()).toContain('No columns on this board.')
  })

  it('shows the empty-board hint in the header label as "0 columns · 0 tasks"', () => {
    wrapper = mount(KanbanList, {
      props: { content: EMPTY_BOARD_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('0 columns')
    expect(wrapper.text()).toContain('0 tasks')
  })

  it('renders the error message in the expanded body on error', async () => {
    wrapper = mount(KanbanList, {
      props: { content: ERROR_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('error')
    expect(wrapper.text()).not.toContain("matches no workspace_item")

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Error:')
    expect(wrapper.text()).toContain('matches no workspace_item')
  })

  it('handles a "Missing required field" error', () => {
    wrapper = mount(KanbanList, {
      props: { content: MISSING_FIELD_ERROR, expanded: true },
    })
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).toContain('Missing required field: workspace_id')
  })

  it('auto-expands when expanded prop is true', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    expect(wrapper.text()).toContain('Columns (3)')
  })

  it('does not render the Tasks section when there are 0 tasks (with columns)', () => {
    wrapper = mount(KanbanList, {
      props: { content: NO_TASKS_BUT_HAS_COLUMNS, expanded: true },
    })
    expect(wrapper.text()).toContain('Columns (1)')
    expect(wrapper.text()).not.toContain('Tasks (0)')
  })

  it('shows + toggle when collapsed and − when expanded', async () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('+')
    expect(wrapper.text()).not.toContain('−')

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('−')
    expect(wrapper.text()).not.toContain('+')
  })

  it('does NOT include an emoji in the header (matches other tool components which are emoji-free)', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML },
    })
    expect(wrapper.text()).not.toMatch(/[\u{1F300}-\u{1FAFF}]/u)
  })

  it('does not leak XML fragments into the visible text', () => {
    wrapper = mount(KanbanList, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    const text = wrapper.text()
    expect(text).not.toContain('<kanban>')
    expect(text).not.toContain('<column>')
    expect(text).not.toContain('<task>')
    expect(text).not.toContain('<workspace_id>')
    expect(text).not.toContain('<position>')
  })
})
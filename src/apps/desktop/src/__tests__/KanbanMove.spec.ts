/** Tests for KanbanMove.vue — the tool_output component that renders the XML response from the
 * `kanban_move_task` agent tool. The component is purely presentational (no API calls), so no mocks
 * are needed. Mirrors the SetGitWorktree tool_output style. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import KanbanMove from '../components/tool_outputs/KanbanMove.vue'

const SUCCESS_XML = {
  success: true,
  task_id: 'task_1782549179378',
  task_name: 'fix-blocking-sse-call',
  column_id: 'col_1782442554114534970',
  column_name: 'in progress',
  position: 0,
}

const ERROR_XML = { success: false, error: 'TaskNotFound: task_9999' }

const MISSING_FIELD_ERROR = { success: false, error: 'Missing required field: workspace_id' }

const AMBIGUOUS_ERROR = {
  success: false,
  error: "Ambiguous column name: 'done' matches 2 columns - pass target_column_id",
}

describe('KanbanMove', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the tool name "kanban_move_task" in the header', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('kanban_move_task')
  })

  it('shows the task name and column name in the collapsed header on success', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('fix-blocking-sse-call')
    expect(wrapper.text()).toContain('in progress')
  })

  it('shows the ✓ status indicator on success', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('shows the ✗ status indicator on error', () => {
    wrapper = mount(KanbanMove, {
      props: { content: ERROR_XML },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('hides the task_id copy button on error', () => {
    wrapper = mount(KanbanMove, {
      props: { content: ERROR_XML, expanded: true },
    })
    expect(wrapper.find('button[title="Copy task id"]').exists()).toBe(false)
  })

  it('shows the copy task_id button on success', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    expect(wrapper.find('button[title="Copy task id"]').exists()).toBe(true)
  })

  it('expands to show the task/column/position rows when clicked', async () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    // Collapsed: position row not visible
    expect(wrapper.text()).not.toContain('Position:')

    // Click the header to expand
    await wrapper.find('[role="button"]').trigger('click')

    expect(wrapper.text()).toContain('Task:')
    expect(wrapper.text()).toContain('Column:')
    expect(wrapper.text()).toContain('Position:')
    expect(wrapper.text()).toContain('0')
  })

  it('renders the full task_name, task_id, column_name, column_id in the expanded body', async () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    const text = wrapper.text()
    expect(text).toContain('fix-blocking-sse-call')
    expect(text).toContain('task_1782549179378')
    expect(text).toContain('in progress')
    expect(text).toContain('col_1782442554114534970')
  })

  it('renders the error message in the expanded body', async () => {
    wrapper = mount(KanbanMove, {
      props: { content: ERROR_XML, expanded: false },
    })
    expect(wrapper.text()).not.toContain('TaskNotFound')

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Error:')
    expect(wrapper.text()).toContain('TaskNotFound: task_9999')
  })

  it('auto-expands when expanded prop is true', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: true },
    })
    expect(wrapper.text()).toContain('Position:')
    expect(wrapper.text()).toContain('0')
  })

  it('handles a "Missing required field" error', () => {
    wrapper = mount(KanbanMove, {
      props: { content: MISSING_FIELD_ERROR, expanded: true },
    })
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).toContain('Missing required field: workspace_id')
    // Task row should NOT appear on error
    expect(wrapper.text()).not.toContain('Task:')
  })

  it('handles an ambiguous column name error', () => {
    wrapper = mount(KanbanMove, {
      props: { content: AMBIGUOUS_ERROR, expanded: true },
    })
    expect(wrapper.text()).toContain('Ambiguous column name')
    expect(wrapper.text()).toContain("matches 2 columns")
  })

  it('shows "error" in the header on failure (not the XML)', () => {
    wrapper = mount(KanbanMove, {
      props: { content: ERROR_XML, expanded: false },
    })
    // The header label should be "error", not the leaked XML
    expect(wrapper.text()).toContain('error')
    // Make sure no XML fragments leak into the header
    expect(wrapper.text()).not.toContain('<kanban_move>')
    expect(wrapper.text()).not.toContain('<success>')
  })

  it('does NOT include an emoji in the header (matches other tool components which are emoji-free)', () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML },
    })
    expect(wrapper.text()).not.toMatch(/[\u{1F300}-\u{1FAFF}]/u)
  })

  it('shows + toggle when collapsed and − when expanded', async () => {
    wrapper = mount(KanbanMove, {
      props: { content: SUCCESS_XML, expanded: false },
    })
    expect(wrapper.text()).toContain('+')
    expect(wrapper.text()).not.toContain('−')

    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('−')
    expect(wrapper.text()).not.toContain('+')
  })
})
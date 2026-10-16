/** Tests for ProgressiveTool.vue — universal renderer for `search_tool` / `view_tool` / `use_tool`. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ProgressiveTool from '../ProgressiveTool.vue'

const SEARCH_CONTENT = {
  query: 'kanban_list',
  count: 1,
  total: 3,
  tools: [
    {
      name: 'kanban_list',
      kind: 'builtin',
      server: '',
      equipped: 'no',
      summary: 'List a kanban board.',
    },
  ],
  hint: 'Call view_tool for the full parameter schema.',
}

const VIEW_CONTENT = {
  name: 'kanban_list',
  kind: 'builtin',
  server: '',
  equipped: 'no',
  description: 'List a kanban board.',
  parameters: { type: 'object', properties: {}, required: [] },
  hint: 'Call use_tool with this name to enable it.',
}

const USE_CONTENT = {
  name: 'kanban_list',
  kind: 'builtin',
  equipped: true,
  inserted: true,
  wait_next_turn: true,
  note: 'Enabled for this session.',
}

describe('ProgressiveTool', () => {
  it('renders search_tool rows on expand (same card pattern as other tools)', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: SEARCH_CONTENT,
        toolName: 'search_tool',
        parameters: '{}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('search_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('List a kanban board.')
    expect(wrapper.attributes('data-testid') || wrapper.html()).toBeTruthy()
  })

  it('renders view_tool description + pretty parameters on expand', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: VIEW_CONTENT,
        toolName: 'view_tool',
        parameters: '{"name":"kanban_list"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('view_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('List a kanban board.')
    expect(wrapper.text()).toContain('"type": "object"')
  })

  it('renders use_tool enabled state with just the equip note (no repeated schema)', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: USE_CONTENT,
        toolName: 'use_tool',
        parameters: '{"name":"kanban_list"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('use_tool')
    expect(wrapper.text()).toContain('kanban_list')
    expect(wrapper.text()).toContain('enabled')
    expect(wrapper.text()).toContain('Enabled for this session.')
    // No repeated parameter schema — view_tool already showed it.
    expect(wrapper.find('[data-testid="progressive-tool-parameters"]').exists()).toBe(false)
  })

  it('renders the error envelope', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: {
          name: 'nope',
          found: false,
          error: "unknown tool 'nope' — not in this session's tool catalog",
          hint: 'Call search_tool to list candidates.',
        },
        toolName: 'view_tool',
        parameters: '{"name":"nope"}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('Error')
    expect(wrapper.text()).toContain('unknown tool')
  })

  it('collapses when expanded=false (header only, same as other cards)', () => {
    const wrapper = mount(ProgressiveTool, {
      props: {
        content: SEARCH_CONTENT,
        toolName: 'search_tool',
        parameters: '{}',
        expanded: false,
      },
    })
    // Header is always visible…
    expect(wrapper.text()).toContain('search_tool')
    // …but rows stay hidden until expand.
    expect(wrapper.text()).not.toContain('List a kanban board.')
  })
})

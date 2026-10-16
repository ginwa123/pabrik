/** Tests for McpTool.vue — the universal renderer for ANY `mcp_*` tool. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import McpTool from '../McpTool.vue'

describe('McpTool', () => {
  it('renders graphify stats as raw text (the screenshot case)', () => {
    const wrapper = mount(McpTool, {
      props: {
        content: 'Nodes: 14885 Edges: 21958 Communities: 906',
        toolName: 'mcp_graphify_graph_stats',
        parameters: '{}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('graphify · graph_stats')
    expect(wrapper.text()).toContain('Nodes: 14885')
    // No DiffView frame, no "(no content)" placeholder.
    expect(wrapper.text()).not.toContain('no content')
    expect(wrapper.text()).not.toContain('BEFORE')
  })

  it('pretty-prints JSON output from any server (e.g. mcp_db)', () => {
    const wrapper = mount(McpTool, {
      props: {
        content: '{"rows":[{"id":1}]}',
        toolName: 'mcp_db_query',
        parameters: '{}',
        expanded: true,
      },
    })
    expect(wrapper.text()).toContain('db · query')
    expect(wrapper.text()).toContain('"id": 1')
  })

  it('renders the error envelope', () => {
    const envelope = JSON.stringify({
      tool: 'mcp_graphify_graph_stats',
      parameters: {},
      success: false,
      data: null,
      error: 'connection refused',
      v: 1,
    })
    const wrapper = mount(McpTool, {
      props: { content: envelope, toolName: 'mcp_graphify_graph_stats', expanded: true },
    })
    expect(wrapper.text()).toContain('connection refused')
  })

  it('shows Arguments only when params are non-empty', () => {
    const withArgs = mount(McpTool, {
      props: {
        content: 'ok',
        toolName: 'mcp_db_query',
        parameters: '{"q":"select 1"}',
        expanded: true,
      },
    })
    expect(withArgs.text()).toContain('Arguments')

    const withoutArgs = mount(McpTool, {
      props: { content: 'ok', toolName: 'mcp_db_query', parameters: '{}', expanded: true },
    })
    expect(withoutArgs.text()).not.toContain('Arguments')
  })
})

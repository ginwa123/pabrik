/**
 * Tests for UsedTools.vue.
 *
 * Wire contract (see `src/modules/agent/tools/used_tools.zig` + the
 * `wrapToolOutput` envelope produced by `tools_exec_used_tools.zig`):
 *   {"tool":"used_tools","parameters":{},"success":true,
 *    "data":{"count":N,"tools":[{"name":…,"description":…}, …]},
 *    "error":null,"v":1}
 *   error: …"success":false,"data":null,"error":"used_tools failed: …"
 *
 * Verifies:
 *  - header chip shows the row count (and the `mcp` tally in right-meta)
 *  - one row per tool with name + FULL description
 *  - `mcp_*` tools get the mcp chip; built-ins do not
 *  - empty listing shows the empty state, not a blank body
 *  - error envelope shows the error text
 *  - malformed content fails closed with a visible error (no crash)
 *  - rows without a name are skipped; a stale `count` never desyncs the card
 *  - the filter box narrows rows and can report "no match"
 *  - the filter resets on collapse so the next open isn't empty
 *  - collapsed by default, expands on header click
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import UsedTools from '../UsedTools.vue'

// ────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────
const tool = (name: string, description = `${name} description.`): Record<string, unknown> => ({
  name,
  description,
})

const makeEnvelope = (tools: unknown[], countOverride?: number): string =>
  JSON.stringify({
    tool: 'used_tools',
    parameters: {},
    success: true,
    data: { count: countOverride ?? tools.length, tools },
    error: null,
    v: 1,
  })

const makeErrorEnvelope = (error: string): string =>
  JSON.stringify({
    tool: 'used_tools',
    parameters: {},
    success: false,
    data: null,
    error,
    v: 1,
  })

const POPULATED = makeEnvelope([
  tool('read_file', 'Read a file by path.'),
  tool('update_plan', 'The `update_plan` tool sets the task plan.'),
  tool('mcp_graphify_query_graph', 'Ask the knowledge graph.'),
])

/** Mount + expand (the body only exists once expanded). */
async function mountExpanded(content: string) {
  const wrapper = mount(UsedTools, {
    props: { message: { content } },
    attachTo: document.body,
  })
  await wrapper.find('[role="button"]').trigger('click')
  return wrapper
}

// ────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────
describe('UsedTools.vue — populated', () => {
  it('header chip shows the tool name and the tool count', () => {
    const wrapper = mount(UsedTools, { props: { message: { content: POPULATED } } })
    expect(wrapper.find('[data-testid="used-tools"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('used_tools')
    expect(wrapper.text()).toContain('3 tools equipped')
  })

  it('is collapsed by default and expands on header click', async () => {
    const wrapper = mount(UsedTools, {
      props: { message: { content: POPULATED } },
      attachTo: document.body,
    })
    expect(wrapper.find('[data-testid="used-tools-body"]').exists()).toBe(false)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="used-tools-body"]').exists()).toBe(true)
  })

  it('renders one row per tool with name and full description', async () => {
    const wrapper = await mountExpanded(POPULATED)
    const rows = wrapper.findAll('[data-testid="used-tools-row"]')
    expect(rows).toHaveLength(3)
    expect(wrapper.text()).toContain('read_file')
    expect(wrapper.text()).toContain('Read a file by path.')
    expect(wrapper.text()).toContain('update_plan')
    expect(wrapper.text()).toContain('The `update_plan` tool sets the task plan.')
    expect(wrapper.text()).toContain('mcp_graphify_query_graph')
    expect(wrapper.text()).toContain('Ask the knowledge graph.')
  })

  it('long descriptions render in FULL (not truncated)', async () => {
    const long = 'DESC-START ' + 'x'.repeat(4000) + ' DESC-END'
    const wrapper = await mountExpanded(makeEnvelope([tool('verbose', long)]))
    const row = wrapper.find('[data-testid="used-tools-row"]')
    expect(row.text()).toContain('DESC-START')
    expect(row.text()).toContain('DESC-END')
    expect(row.text().length).toBeGreaterThan(4000)
  })

  it('chips only the mcp_* tools and tallies them in the header', async () => {
    const wrapper = await mountExpanded(POPULATED)
    const chips = wrapper.findAll('[data-testid="used-tools-mcp-chip"]')
    expect(chips).toHaveLength(1)
    // Right-meta on the collapsed header reports the mcp tally.
    expect(wrapper.text()).toContain('1 mcp')
  })

  it('drops the mcp right-meta when no MCP tool is equipped', () => {
    const wrapper = mount(UsedTools, {
      props: { message: { content: makeEnvelope([tool('read_file'), tool('write_file')]) } },
    })
    expect(wrapper.text()).not.toContain('mcp')
    expect(wrapper.text()).toContain('2 tools equipped')
  })

  it('singularizes a single tool', () => {
    const wrapper = mount(UsedTools, {
      props: { message: { content: makeEnvelope([tool('read_file')]) } },
    })
    expect(wrapper.text()).toContain('1 tool equipped')
    expect(wrapper.text()).not.toContain('1 tools equipped')
  })
})

describe('UsedTools.vue — empty / error / malformed', () => {
  it('empty listing shows the empty state, not a blank body', async () => {
    const wrapper = await mountExpanded(makeEnvelope([]))
    expect(wrapper.find('[data-testid="used-tools-empty"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(0)
    expect(wrapper.text()).toContain('No tools equipped')
  })

  it('error envelope shows the error text and no rows', async () => {
    const wrapper = await mountExpanded(makeErrorEnvelope('used_tools failed: OutOfMemory'))
    expect(wrapper.find('[data-testid="used-tools-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('used_tools failed: OutOfMemory')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(0)
  })

  it('malformed content fails closed with a visible error (no crash)', async () => {
    const wrapper = await mountExpanded('not json at all')
    expect(wrapper.find('[data-testid="used-tools-error"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('malformed tool output')
  })
})

describe('UsedTools.vue — defensive parsing', () => {
  it('skips rows without a name', async () => {
    const content = makeEnvelope([tool('read_file'), { description: 'nameless' }, null, 42])
    const wrapper = await mountExpanded(content)
    const rows = wrapper.findAll('[data-testid="used-tools-row"]')
    expect(rows).toHaveLength(1)
    expect(wrapper.text()).toContain('read_file')
  })

  it('a stale count never desyncs the card from the rendered rows', async () => {
    // Backend says 10, the array carries 2 — the rows are the truth.
    const wrapper = await mountExpanded(makeEnvelope([tool('read_file'), tool('glob')], 10))
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(2)
    expect(wrapper.text()).toContain('2 tools equipped')
  })

  it('tolerates a missing description', async () => {
    const content = JSON.stringify({
      tool: 'used_tools',
      parameters: {},
      success: true,
      data: { count: 1, tools: [{ name: 'bare' }] },
      error: null,
      v: 1,
    })
    const wrapper = await mountExpanded(content)
    expect(wrapper.text()).toContain('bare')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(1)
  })

  it('accepts a bare payload object (no envelope) defensively', async () => {
    const bare = JSON.stringify({ count: 1, tools: [tool('read_file')] })
    const wrapper = await mountExpanded(bare)
    expect(wrapper.text()).toContain('1 tool equipped')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(1)
  })
})

describe('UsedTools.vue — filter box', () => {
  it('narrows rows by name (case-insensitive)', async () => {
    const wrapper = await mountExpanded(POPULATED)
    await wrapper.find('[data-testid="used-tools-filter"]').setValue('READ')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(1)
    expect(wrapper.text()).toContain('read_file')
    expect(wrapper.find('[data-testid="used-tools-filter-count"]').text()).toBe('1/3')
  })

  it('matches on description too', async () => {
    const wrapper = await mountExpanded(POPULATED)
    await wrapper.find('[data-testid="used-tools-filter"]').setValue('knowledge graph')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(1)
    expect(wrapper.text()).toContain('mcp_graphify_query_graph')
  })

  it('reports a no-match state instead of a blank body', async () => {
    const wrapper = await mountExpanded(POPULATED)
    await wrapper.find('[data-testid="used-tools-filter"]').setValue('zzzznope')
    expect(wrapper.find('[data-testid="used-tools-no-match"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(0)
  })

  it('resets on collapse so the next open is not empty', async () => {
    const wrapper = await mountExpanded(POPULATED)
    await wrapper.find('[data-testid="used-tools-filter"]').setValue('read')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(1)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="used-tools-body"]').exists()).toBe(false)
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.findAll('[data-testid="used-tools-row"]')).toHaveLength(3)
  })
})

import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import ToolsSection from '../components/pabrik/ToolsSection.vue'
import * as api from '../api'

vi.mock('../api', () => ({
  getAgentToolsRegistry: vi.fn(),
}))

const mockRegistry = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>

/** Registry fixture covering: several wireframe groups, both special
 * pills (`main-agent only`, `mode floor`), built-in-default members,
 * non-default members, and one tool missing from the static group map
 * (→ the "Other" fallback bucket). */
const REGISTRY = [
  { name: 'command', description: 'Run a shell command' },
  { name: 'read_file', description: "Read a file's contents" },
  { name: 'glob', description: 'Find files by glob pattern' },
  { name: 'update_plan', description: 'Update the task checklist' },
  { name: 'spawn_sub_agent', description: 'Run a task in a sub-agent' },
  { name: 'ask_user', description: 'Ask the human a question' },
  { name: 'kanban_list', description: 'Inspect the kanban board' },
  { name: 'kanban_move_task', description: 'Move a card between columns' },
  { name: 'present_files', description: 'Show files as preview cards' },
  { name: 'add_mcp_server', description: 'Register a new MCP server' },
  { name: 'mystery_tool', description: 'Not in the static group map' },
]

// Built-in defaults ∩ registry: everything except add_mcp_server and
// mystery_tool (neither is part of DEFAULT_AGENT_TOOLS / kanban floor).
const DEFAULTS_IN_REGISTRY = [
  'command',
  'read_file',
  'glob',
  'update_plan',
  'spawn_sub_agent',
  'ask_user',
  'kanban_list',
  'kanban_move_task',
  'present_files',
]

function mountSection(modelValue: string[] | null) {
  return mount(ToolsSection, { props: { modelValue } })
}

function isChecked(wrapper: ReturnType<typeof mountSection>, name: string): boolean {
  const input = wrapper.find(`[data-testid="row-${name}"] input`)
  return (input.element as HTMLInputElement).checked
}

describe('ToolsSection', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockRegistry.mockReset()
    mockRegistry.mockResolvedValue({ tools: REGISTRY })
  })

  it('renders the registry grouped into the wireframe groups with an Other fallback bucket', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    expect(wrapper.find('[data-testid="tools-section"]').exists()).toBe(true)
    // Groups present in the fixture:
    for (const slug of [
      'files-shell',
      'search',
      'planning',
      'sub-agents',
      'interactive',
      'kanban',
      'presentation-media',
      'mcp',
      'other',
    ]) {
      expect(wrapper.find(`[data-testid="group-${slug}"]`).exists()).toBe(true)
    }
    // Groups with no fixture tool don't render.
    expect(wrapper.find('[data-testid="group-git"]').exists()).toBe(false)

    // Unmapped tool lands in the Other bucket (not the MCP group).
    const otherGroup = wrapper.find('[data-testid="group-other"]')
    expect(otherGroup.find('[data-testid="row-mystery_tool"]').exists()).toBe(true)
    expect(
      wrapper.find('[data-testid="group-mcp"] [data-testid="row-mystery_tool"]').exists(),
    ).toBe(false)

    // Rows carry name + registry description.
    const commandRow = wrapper.find('[data-testid="row-command"]')
    expect(commandRow.text()).toContain('command')
    expect(commandRow.text()).toContain('Run a shell command')
  })

  it('shows special pills on main-agent-only and mode-floor tools only', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    expect(wrapper.find('[data-testid="row-spawn_sub_agent"]').text()).toContain('main-agent only')
    expect(wrapper.find('[data-testid="row-ask_user"]').text()).toContain('main-agent only')
    expect(wrapper.find('[data-testid="row-kanban_list"]').text()).toContain('mode floor')
    expect(wrapper.find('[data-testid="row-kanban_move_task"]').text()).toContain('mode floor')
    expect(wrapper.find('[data-testid="row-command"]').text()).not.toContain('main-agent only')
    expect(wrapper.find('[data-testid="row-command"]').text()).not.toContain('mode floor')
  })

  it('modelValue=null shows the built-in defaults plus the defaults-note', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    expect(wrapper.find('[data-testid="defaults-note"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="defaults-note"]').text()).toContain(
      'Built-in defaults — nothing is written to config.json until you change a tool.',
    )
    // Built-in defaults are checked…
    expect(isChecked(wrapper, 'command')).toBe(true)
    expect(isChecked(wrapper, 'kanban_move_task')).toBe(true)
    // …non-default tools are not.
    expect(isChecked(wrapper, 'add_mcp_server')).toBe(false)
    expect(isChecked(wrapper, 'mystery_tool')).toBe(false)
    // Summary counts only registry tools that are selected.
    expect(wrapper.find('[data-testid="tools-section"]').text()).toContain(
      `${DEFAULTS_IN_REGISTRY.length} of ${REGISTRY.length} tools selected`,
    )
  })

  it('given an explicit modelValue, reflects it exactly (no defaults bleed, no note)', async () => {
    const wrapper = mountSection(['add_mcp_server'])
    await flushPromises()

    expect(wrapper.find('[data-testid="defaults-note"]').exists()).toBe(false)
    expect(isChecked(wrapper, 'add_mcp_server')).toBe(true)
    expect(isChecked(wrapper, 'command')).toBe(false)
    expect(isChecked(wrapper, 'glob')).toBe(false)
    expect(wrapper.find('[data-testid="tools-section"]').text()).toContain(
      `1 of ${REGISTRY.length} tools selected`,
    )
  })

  it('toggling a checkbox emits change with the FULL explicit array', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    // mystery_tool is off in the defaults → checking it must emit
    // every selected name (defaults + the new one), not just the delta.
    await wrapper.find('[data-testid="row-mystery_tool"] input').setValue(true)
    const emitted = wrapper.emitted('change')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toEqual([...DEFAULTS_IN_REGISTRY, 'mystery_tool'])
  })

  it('unchecking a default emits the remaining full array', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    await wrapper.find('[data-testid="row-glob"] input').setValue(false)
    const emitted = wrapper.emitted('change')
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toEqual(DEFAULTS_IN_REGISTRY.filter((n) => n !== 'glob'))
  })

  it('All selects every registry tool; None clears to an empty array', async () => {
    const wrapper = mountSection(null)
    await flushPromises()

    await wrapper.find('[data-testid="all-btn"]').trigger('click')
    expect(wrapper.emitted('change')![0]![0]).toEqual(REGISTRY.map((t) => t.name))

    await wrapper.setProps({ modelValue: REGISTRY.map((t) => t.name) })
    await wrapper.find('[data-testid="none-btn"]').trigger('click')
    expect(wrapper.emitted('change')![1]![0]).toEqual([])
  })

  it('clicking a group header toggles the whole group', async () => {
    const wrapper = mountSection([])
    await flushPromises()

    const groupHead = () => wrapper.find('[data-testid="group-files-shell"] > button')
    await groupHead().trigger('click')
    expect(wrapper.emitted('change')![0]![0]).toEqual(['command', 'read_file'])

    // With the whole group selected, the next click clears it.
    await wrapper.setProps({ modelValue: ['command', 'read_file'] })
    await groupHead().trigger('click')
    expect(wrapper.emitted('change')![1]![0]).toEqual([])
  })

  it('renders the group count from selected/total and turns it green when complete', async () => {
    const wrapper = mountSection(['command', 'read_file'])
    await flushPromises()

    const head = wrapper.find('[data-testid="group-files-shell"] > button')
    expect(head.text()).toContain('2/2')
    expect(head.find('span:last-child').attributes('style')).toContain('var(--color-green)')

    const searchHead = wrapper.find('[data-testid="group-search"] > button')
    expect(searchHead.text()).toContain('0/1')
    expect(searchHead.find('span:last-child').attributes('style')).toContain(
      'var(--semantic-text-dim)',
    )
  })
})

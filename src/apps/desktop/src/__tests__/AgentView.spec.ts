// Behavioural tests for AgentView. Mounts the component with stub
// props and asserts the wired emits + conditional rendering.
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentView from '../components/views/AgentView.vue'
import * as api from '../api'

const baseItem = { id: 'item_1', name: 'My Agent', path: '/tmp', item_type: 'agent' }
const baseProps = () => ({
  item: baseItem,
  workspaceId: 'ws_1',
  itemId: 'item_1',
  knowledge: [] as api.AgentKnowledgeRow[],
  tools: [] as string[],
})

const mockRegistry = {
  tools: [
    { name: 'bash', description: 'Run shell commands' },
    { name: 'read_file', description: 'Read a file from disk' },
    { name: 'write_file', description: 'Write content to disk' },
    { name: 'kanban_list', description: 'List kanban columns and tasks' },
  ],
}

describe('AgentView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue(mockRegistry)
  })

  it('renders Knowledge panel with empty state when no entries', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    expect(wrapper.find('[data-testid="agent-knowledge-panel"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No knowledge files yet')
  })

  it('emits addKnowledge when + Add is clicked', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await wrapper.find('[data-testid="agent-add-knowledge"]').trigger('click')
    expect(wrapper.emitted('addKnowledge')).toBeTruthy()
  })

  it('renders knowledge count chip with the entry count', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_1',
            agent_id: 'item_1',
            file_path: '/home/me/spec.md',
            label: 'Spec',
            content: '',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const chip = wrapper.find('[data-testid="agent-knowledge-count"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toBe('1')
  })

  it('renders knowledge items with remove button', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_1',
            agent_id: 'item_1',
            file_path: '/home/me/spec.md',
            label: 'Spec',
            content: '',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const items = wrapper.findAll('[data-testid="agent-knowledge-item"]')
    expect(items.length).toBe(1)
    await wrapper.find('[data-testid="agent-remove-knowledge"]').trigger('click')
    expect(wrapper.emitted('removeKnowledge')![0]).toEqual(['k_1'])
  })

  it('renders an Inline text badge for content rows instead of a file path', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_inline',
            agent_id: 'item_1',
            file_path: '',
            label: 'Notes',
            content: 'Manual knowledge body for the agent to read.',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const item = wrapper.find('[data-testid="agent-knowledge-item"]')
    expect(item.exists()).toBe(true)
    // Label shown as the title.
    expect(item.text()).toContain('Notes')
    // "Inline text" badge present.
    expect(item.text()).toContain('Inline text')
    // No absolute path rendered.
    expect(item.text()).not.toContain('/')
  })

  it('renders Tools panel with registry checkboxes', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    // Wait for the registry fetch to settle.
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const tools = wrapper.findAll('[data-testid="agent-tool-item"]')
    expect(tools.length).toBe(4)
    expect(wrapper.text()).toContain('bash')
    expect(wrapper.text()).toContain('read_file')
  })

  it('emits toggleTool with (name, enabled) on checkbox change', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const bashCheckbox = wrapper.find('[data-testid="agent-tool-checkbox-bash"]')
    expect(bashCheckbox.exists()).toBe(true)
    await bashCheckbox.setValue(true)
    expect(wrapper.emitted('toggleTool')![0]).toEqual(['bash', true])
  })

  it('shows the enabled tools count chip as `N / total`', async () => {
    const wrapper = mount(AgentView, {
      props: { ...baseProps(), tools: ['bash', 'read_file'] },
    })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const chip = wrapper.find('[data-testid="agent-tools-count"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toBe('2 / 4')
  })

  it('renders an ON chip for enabled tools', async () => {
    const wrapper = mount(AgentView, {
      props: { ...baseProps(), tools: ['bash'] },
    })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const enabledChips = wrapper.findAll('[data-testid="agent-tool-enabled-chip"]')
    expect(enabledChips.length).toBe(1)
  })

  describe('search filter', () => {
    it('filters the tools list by name (case-insensitive)', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('BASH')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(1)
      expect(visible[0]!.text()).toContain('bash')
    })

    it('filters the tools list by description', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('kanban')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(1)
      expect(visible[0]!.text()).toContain('kanban_list')
    })

    it('shows the empty-search state when no tools match', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('zzzzz')
      await nextTick()
      const empty = wrapper.find('[data-testid="agent-tools-empty-search"]')
      expect(empty.exists()).toBe(true)
      expect(wrapper.findAll('[data-testid="agent-tool-item"]').length).toBe(0)
    })

    it('updates the filter-status text to reflect matches', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('file')
      await nextTick()
      const status = wrapper.find('[data-testid="agent-tools-filter-status"]')
      expect(status.text()).toContain('2')
    })
  })

  describe('bulk ops', () => {
    it('Select all emits toggleToolsBulk with all un-enabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(false)
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')
      expect(events).toBeTruthy()
      const [names, enabled] = events![0] as [string[], boolean]
      expect(enabled).toBe(true)
      expect(names.sort()).toEqual(['kanban_list', 'read_file', 'write_file'].sort())
    })

    it('Select all is disabled when every visible tool is already enabled', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash', 'read_file', 'write_file', 'kanban_list'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
    })

    it('Clear emits toggleToolsBulk with all enabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash', 'read_file'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-clear-all"]')
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')
      expect(events).toBeTruthy()
      const [names, enabled] = events![0] as [string[], boolean]
      expect(enabled).toBe(false)
      expect(names.sort()).toEqual(['bash', 'read_file'].sort())
    })

    it('Clear is disabled when no visible tools are enabled', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-clear-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
    })

    it('Select all only includes the filtered (visible) tools', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('file')
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')!
      const [names, enabled] = events[0] as [string[], boolean]
      expect(enabled).toBe(true)
      expect(names.sort()).toEqual(['read_file', 'write_file'].sort())
    })
  })

  it('does not render a New Chat button (removed 2026-08-23)', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    expect(wrapper.find('[data-testid="agent-new-chat"]').exists()).toBe(false)
    expect(wrapper.emitted('newChat')).toBeFalsy()
  })

  // ─── Feature B1: description clamp + expander (2026-08-22) ──────────
  describe('tool description expand/collapse', () => {
    it('renders descriptions clamped by default (no agent-desc-clamped after expand)', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const desc = wrapper.find('[data-testid="agent-tool-desc-bash"]')
      expect(desc.exists()).toBe(true)
      expect(desc.classes()).toContain('agent-desc-clamped')
      // Expand it.
      await wrapper.find('[data-testid="agent-tool-expand-bash"]').trigger('click')
      expect(desc.classes()).not.toContain('agent-desc-clamped')
      // Collapse again.
      await wrapper.find('[data-testid="agent-tool-expand-bash"]').trigger('click')
      expect(desc.classes()).toContain('agent-desc-clamped')
    })

    it('clicking the description text toggles expansion too', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const desc = wrapper.find('[data-testid="agent-tool-desc-bash"]')
      await desc.trigger('click')
      expect(desc.classes()).not.toContain('agent-desc-clamped')
    })

    it('expansion is per-tool (independent rows)', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tool-expand-bash"]').trigger('click')
      expect(wrapper.find('[data-testid="agent-tool-desc-bash"]').classes()).not.toContain('agent-desc-clamped')
      expect(wrapper.find('[data-testid="agent-tool-desc-read_file"]').classes()).toContain('agent-desc-clamped')
    })
  })

  // ─── Feature B2: All / Enabled / Disabled filter chips ──────────────
  describe('enabled-state filter chips', () => {
    it('renders All/Enabled/Disabled chips with live counts', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      expect(wrapper.find('[data-testid="agent-tools-filter-all"]').text()).toBe('All (4)')
      expect(wrapper.find('[data-testid="agent-tools-filter-enabled"]').text()).toBe('Enabled (1)')
      expect(wrapper.find('[data-testid="agent-tools-filter-disabled"]').text()).toBe('Disabled (3)')
    })

    it('Enabled chip narrows the list to enabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash', 'read_file'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-filter-enabled"]').trigger('click')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(2)
      expect(wrapper.text()).toContain('bash')
      expect(wrapper.text()).toContain('read_file')
      expect(wrapper.text()).not.toContain('write_file')
    })

    it('Disabled chip narrows the list to disabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-filter-disabled"]').trigger('click')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(3)
      expect(wrapper.text()).not.toContain('bash')
    })

    it('filter composes with search query', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-filter-disabled"]').trigger('click')
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('file')
      await nextTick()
      // 'file' matches read_file + write_file + kanban_list (description),
      // but only disabled ones survive → read_file + write_file.
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(2)
    })

    it('shows the filter empty state with a reset when Enabled has no matches', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-filter-enabled"]').trigger('click')
      await nextTick()
      const empty = wrapper.find('[data-testid="agent-tools-empty-filter"]')
      expect(empty.exists()).toBe(true)
      expect(empty.text()).toContain('No enabled tools')
      // Reset returns to All.
      await wrapper.find('[data-testid="agent-tools-empty-filter-reset"]').trigger('click')
      await nextTick()
      expect(wrapper.findAll('[data-testid="agent-tool-item"]').length).toBe(4)
    })

    it('bulk Select all still operates on the filtered visible set', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-filter-disabled"]').trigger('click')
      await nextTick()
      await wrapper.find('[data-testid="agent-tools-select-all"]').trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')!
      const [names, enabled] = events[0] as [string[], boolean]
      expect(enabled).toBe(true)
      expect(names.sort()).toEqual(['kanban_list', 'read_file', 'write_file'].sort())
    })
  })

  // ─── Feature A1/A3: knowledge expand/collapse + copy ────────────────
  describe('knowledge expand/collapse', () => {
    const inlineRow = () => ({
      id: 'k_inline',
      agent_id: 'item_1',
      file_path: '',
      label: 'Notes',
      content: 'Line one of knowledge.\nLine two of knowledge.',
      position: 0,
      created_at: '',
      updated_at: '',
    })

    it('expands an inline row to reveal full content + copy button', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), knowledge: [inlineRow()] },
      })
      await nextTick()
      expect(wrapper.find('[data-testid="agent-knowledge-detail"]').exists()).toBe(false)
      await wrapper.find('[data-testid="agent-knowledge-expand-k_inline"]').trigger('click')
      await nextTick()
      const detail = wrapper.find('[data-testid="agent-knowledge-detail"]')
      expect(detail.exists()).toBe(true)
      expect(detail.text()).toContain('Line two of knowledge.')
      expect(wrapper.find('[data-testid="agent-knowledge-copy"]').exists()).toBe(true)
    })

    it('expands a file-backed row to show path + hint (no copy)', async () => {
      const wrapper = mount(AgentView, {
        props: {
          ...baseProps(),
          knowledge: [
            {
              id: 'k_file',
              agent_id: 'item_1',
              file_path: '/home/me/spec.md',
              label: 'Spec',
              content: '',
              position: 0,
              created_at: '',
              updated_at: '',
            },
          ],
        },
      })
      await nextTick()
      await wrapper.find('[data-testid="agent-knowledge-expand-k_file"]').trigger('click')
      await nextTick()
      const detail = wrapper.find('[data-testid="agent-knowledge-detail"]')
      expect(detail.exists()).toBe(true)
      expect(detail.text()).toContain('/home/me/spec.md')
      expect(detail.text()).toContain('File-backed')
      expect(wrapper.find('[data-testid="agent-knowledge-copy"]').exists()).toBe(false)
    })

    it('emits editKnowledge with the row when ✎ is clicked', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), knowledge: [inlineRow()] },
      })
      await nextTick()
      await wrapper.find('[data-testid="agent-edit-knowledge"]').trigger('click')
      const events = wrapper.emitted('editKnowledge')
      expect(events).toBeTruthy()
      expect((events![0] as unknown[])[0]).toMatchObject({ id: 'k_inline', label: 'Notes' })
    })
  })

  // ─── System Prompt section (plan 2026-08-21-agent-system-prompt) ────
  describe('System Prompt section', () => {
    const promptRow = () => ({
      id: 'asp_1',
      agent_id: 'item_1',
      title: 'Persona',
      content: 'You are a pirate captain.',
      position: 0,
      created_at: '',
      updated_at: '',
    })

    it('renders the system-prompt panel in the main content area', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      expect(wrapper.find('[data-testid="agent-system-prompt-panel"]').exists()).toBe(true)
    })

    it('shows an empty state when no prompts exist', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      expect(wrapper.text()).toContain('No system prompts yet')
    })

    it('renders rows from the systemPrompts prop', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), systemPrompts: [promptRow()] },
      })
      await nextTick()
      expect(wrapper.find('[data-testid="agent-system-prompt-item"]').exists()).toBe(true)
      expect(wrapper.text()).toContain('Persona')
    })

    it('emits addSystemPrompt when + Add is clicked', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await wrapper.find('[data-testid="agent-add-system-prompt"]').trigger('click')
      expect(wrapper.emitted('addSystemPrompt')).toBeTruthy()
    })

    it('emits editSystemPrompt with the row when ✎ is clicked', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), systemPrompts: [promptRow()] },
      })
      await nextTick()
      await wrapper.find('[data-testid="agent-edit-system-prompt"]').trigger('click')
      const events = wrapper.emitted('editSystemPrompt')
      expect(events).toBeTruthy()
      expect((events![0] as unknown[])[0]).toMatchObject({ id: 'asp_1', title: 'Persona' })
    })

    it('emits removeSystemPrompt with the id when ✕ is clicked', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), systemPrompts: [promptRow()] },
      })
      await nextTick()
      await wrapper.find('[data-testid="agent-remove-system-prompt"]').trigger('click')
      expect(wrapper.emitted('removeSystemPrompt')).toBeTruthy()
      expect(wrapper.emitted('removeSystemPrompt')![0]).toEqual(['asp_1'])
    })
  })
})
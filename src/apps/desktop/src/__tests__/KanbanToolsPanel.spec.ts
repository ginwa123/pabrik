// Behavioural tests for KanbanToolsPanel — the per-board tool allowlist panel (extracted from
// KanbanAgentPanel in iteration 2 of the kanban-agent-as-tab plan: 2026-08-27). Mounted as the
// ?tab=tools tab body inside KanbanSettingsView.
// Hosts ONLY the tools checkbox grid; knowledge + system prompts live in KanbanKnowledgePanel.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanToolsPanel from '@/components/views/KanbanToolsPanel.vue'
import * as api from '@/api'
import type { AgentKanban, AgentRegistryEntry } from '@/api'

const kanbanItem = { id: 'wi_kanban', name: 'Sprint 12' }
const baseProps = () => ({ item: kanbanItem, workspaceId: 'ws_1' })

const mockRegistry: { tools: AgentRegistryEntry[] } = {
  tools: [
    { name: 'bash', description: 'Run shell commands' },
    { name: 'read_file', description: 'Read a file from disk' },
    { name: 'write_file', description: 'Write content to disk' },
  ],
}

const configuredBundle = {
  agent_kanban: {
    id: 'wi_kanban',
    workspace_item_id: 'wi_kanban',
    description: '',
    created_at: '2026-08-27T10:00:00Z',
    updated_at: '2026-08-27T10:00:00Z',
  } satisfies AgentKanban,
  knowledges: [],
  tools: ['bash'] as string[],
  system_prompts: [],
}

let wrapper: VueWrapper | null = null

function mountPanel(props = baseProps()) {
  wrapper = mount(KanbanToolsPanel, { props, attachTo: document.body })
  return wrapper
}

function maybeQ<T extends Element = HTMLElement>(testid: string): T | null {
  return document.querySelector<T>(`[data-testid="${testid}"]`)
}

function q<T extends Element = HTMLElement>(testid: string): T {
  const el = maybeQ<T>(testid)
  if (!el) throw new Error(`missing [data-testid="${testid}"]`)
  return el
}

afterEach(() => {
  wrapper?.unmount()
  wrapper = null
})

describe('KanbanToolsPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue(mockRegistry)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(configuredBundle)
  })

  it('renders the tools checkbox grid once data loads', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-tools-panel')).not.toBeNull()
  })

  it('renders one checkbox per registry tool, marked checked when in the enabled list', async () => {
    mountPanel()
    await flushPromises()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    expect(bashCheckbox.checked).toBe(true)
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    expect(readFileCheckbox.checked).toBe(false)
  })

  it('calls enableAgentKanbanTool when a disabled checkbox is toggled on', async () => {
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    readFileCheckbox.checked = true
    readFileCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    expect(enableSpy).toHaveBeenCalledWith('wi_kanban', 'read_file')
  })

  it('calls disableAgentKanbanTool when an enabled checkbox is toggled off', async () => {
    const disableSpy = vi
      .spyOn(api, 'disableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.disableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    bashCheckbox.checked = false
    bashCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    expect(disableSpy).toHaveBeenCalledWith('wi_kanban', 'bash')
  })

  it('shows the unconfigured empty state with a tools picker when no agent_kanban row exists', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-tools-unconfigured')).not.toBeNull()
    const tools = document.querySelectorAll('[data-testid^="kanban-agent-tool-"]')
    expect(tools.length).toBeGreaterThanOrEqual(mockRegistry.tools.length)
  })

  it('does NOT render knowledge or system-prompt sections (those moved to KanbanKnowledgePanel)', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-knowledge-panel')).toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-panel')).toBeNull()
  })

  // ─── Bootstrap flow (unconfigured → configured) ───────────────────────── When the board has no
  // agent_kanbans row yet, clicking a checkbox must still call enableAgentKanbanTool — the backend
  // auto-seeds the row in agent_kanban_tools_create.zig.
  // After success the panel refetches the bundle so config is populated and the unconfigured banner
  // disappears.
  it('lets the user bootstrap the config by enabling a tool from the unconfigured state', async () => {
    // First GET resolves to null (no config yet).
    const getSpy = vi.spyOn(api, 'getAgentKanban')
    getSpy.mockResolvedValueOnce(null)
    // Then, after the first enable lands, the panel refetches and gets
    // a real bundle (mirroring what the backend auto-seeded).
    getSpy.mockResolvedValueOnce({
      ...configuredBundle,
      tools: ['read_file'],
    })
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)

    mountPanel()
    await flushPromises()
    // Pre-fix bug would silently drop the click.
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    readFileCheckbox.checked = true
    readFileCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    await flushPromises()

    expect(enableSpy).toHaveBeenCalledWith('wi_kanban', 'read_file')
    // After the refetch, the bundle is loaded → unconfigured banner is gone.
    expect(maybeQ('kanban-tools-unconfigured')).toBeNull()
    expect(maybeQ('kanban-agent-tools-panel')).not.toBeNull()
  })

  it('falls back to kanbanId (not config.value.id) for the first enable when unconfigured', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)

    mountPanel()
    await flushPromises()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    bashCheckbox.checked = true
    bashCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    // The first arg of enableAgentKanbanTool is the kanban id, which
    // equals props.item.id (wi_kanban) — NOT config.value.id (null).
    expect(enableSpy).toHaveBeenCalledWith('wi_kanban', 'bash')
  })

  it('keeps the checkbox checked after a successful enable from the unconfigured state (optimistic UI)', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    vi.spyOn(api, 'enableAgentKanbanTool').mockResolvedValue(
      {} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>,
    )

    mountPanel()
    await flushPromises()
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    readFileCheckbox.checked = true
    readFileCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()

    // After the optimistic flip + successful POST, the checkbox stays
    // checked (no revert). The backend auto-seeded the row and the
    // optimistic update is the source of truth in the UI.
    expect(readFileCheckbox.checked).toBe(true)
  })

  // ─── Search filter ──────────────────────────────────────────────────────
  it('filters the tools grid by name when the user types into the search box', async () => {
    mountPanel()
    await flushPromises()
    const search = q<HTMLInputElement>('kanban-tools-search') as HTMLInputElement
    search.value = 'read'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Only `read_file` should still be in the grid.
    const labels = Array.from(
      document.querySelectorAll('[data-testid^="kanban-agent-tool-"]'),
    ).filter((el) => !el.getAttribute('data-testid')?.startsWith('kanban-agent-tool-check-'))
    expect(labels.length).toBe(1)
    expect(labels[0]!.getAttribute('data-testid')).toBe('kanban-agent-tool-read_file')
  })

  it('shows an empty-state hint when the search has zero matches', async () => {
    mountPanel()
    await flushPromises()
    const search = q<HTMLInputElement>('kanban-tools-search') as HTMLInputElement
    search.value = 'totally-not-a-tool-xyz'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(maybeQ('kanban-tools-empty')).not.toBeNull()
  })

  // ─── Recommended starter set ───────────────────────────────────────────
  it('enables the recommended starter set when the user clicks the preset button', async () => {
    // Use an empty-tools bundle so preset has clean work to do.
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      tools: [],
    })
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)

    mountPanel()
    await flushPromises()
    const preset = q<HTMLButtonElement>('kanban-tools-preset-recommended')
    preset.click()
    await flushPromises()

    expect(enableSpy).toHaveBeenCalled()
    // Every preset tool got an enable call (RECOMMENDED_TOOLS list,
    // filtered by registry presence — the mock registry has no
    // `command`, so only read_file + write_file fire).
    const calledTools = enableSpy.mock.calls.map((c) => c[1]).sort()
    expect(calledTools).toEqual(['read_file', 'write_file'])
  })

  // unify-command: the preset enables `command` (unified shell) when the
  // registry advertises it; legacy `bash` is NOT equipped anymore, so it
  // is never part of the starter set even when advertised.
  it('includes command (not bash) in the recommended starter set when the registry advertises it', async () => {
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue({
      tools: [
        { name: 'bash', description: 'Run shell commands (legacy)' },
        { name: 'command', description: 'Run shell commands (unified)' },
        { name: 'read_file', description: 'Read a file from disk' },
        { name: 'write_file', description: 'Write content to disk' },
      ],
    })
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      tools: [],
    })
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)

    mountPanel()
    await flushPromises()
    const preset = q<HTMLButtonElement>('kanban-tools-preset-recommended')
    preset.click()
    await flushPromises()

    const calledTools = enableSpy.mock.calls.map((c) => c[1]).sort()
    expect(calledTools).toEqual(['command', 'read_file', 'write_file'])
  })
})

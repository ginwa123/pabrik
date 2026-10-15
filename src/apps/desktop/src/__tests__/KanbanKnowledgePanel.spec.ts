// Behavioural tests for KanbanKnowledgePanel — the per-board persona content panel (Knowledge rows
// + System Prompt blocks).

// Extracted from KanbanAgentPanel in iteration 2 of the kanban-agent-as-tab plan (2026-08-27): the
// Agent umbrella tab was split into Tools + Knowledge as separate top-level tabs. Mounted as the
// ?tab=knowledge tab body inside KanbanSettingsView.

// Hosts the 2 persona-content sections + the 3 reused sub-dialogs. Tools checkbox grid moved to
// KanbanToolsPanel.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { flushPromises } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'

import KanbanKnowledgePanel from '@/components/views/KanbanKnowledgePanel.vue'
import * as api from '@/api'
import type {
  AgentKanban,
  AgentKanbanKnowledgeRow,
  AgentKanbanSystemPromptRow,
} from '@/api'

const kanbanItem = { id: 'wi_kanban', name: 'Sprint 12' }
const baseProps = () => ({ item: kanbanItem, workspaceId: 'ws_1' })

const configuredBundle = {
  agent_kanban: {
    id: 'wi_kanban',
    workspace_item_id: 'wi_kanban',
    description: '',
    created_at: '2026-08-27T10:00:00Z',
    updated_at: '2026-08-27T10:00:00Z',
  } satisfies AgentKanban,
  knowledges: [] as AgentKanbanKnowledgeRow[],
  tools: ['bash'] as string[],
  system_prompts: [] as AgentKanbanSystemPromptRow[],
}

let wrapper: VueWrapper | null = null

function mountPanel(props = baseProps()) {
  wrapper = mount(KanbanKnowledgePanel, { props, attachTo: document.body })
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

function removeTeleportedSubdialogs() {
  document
    .querySelectorAll(
      '[data-testid="agent-knowledge-dialog"], [data-testid="agent-knowledge-detail-dialog"], [data-testid="agent-system-prompt-dialog"]',
    )
    .forEach((el) => el.remove())
}

afterEach(() => {
  wrapper?.unmount()
  wrapper = null
  removeTeleportedSubdialogs()
})

describe('KanbanKnowledgePanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(configuredBundle)
  })

  it('renders BOTH the Knowledge and System Prompt sections once data loads', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-knowledge-panel')).not.toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-panel')).not.toBeNull()
  })

  it('does NOT render the tools checkbox grid (that moved to KanbanToolsPanel)', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-tools-panel')).toBeNull()
  })

  it('renders existing knowledge rows with label and edit/remove buttons', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      knowledges: [
        {
          id: 'k_1',
          kanban_id: 'wi_kanban',
          file_path: '/home/me/spec.md',
          label: 'Spec',
          content: '',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    const row = q('kanban-agent-knowledge-row-k_1')
    expect(row.textContent).toContain('Spec')
    expect(maybeQ('kanban-agent-knowledge-edit-k_1')).not.toBeNull()
    expect(maybeQ('kanban-agent-knowledge-remove-k_1')).not.toBeNull()
  })

  it('calls deleteAgentKanbanKnowledge when the remove button is clicked', async () => {
    const deleteSpy = vi
      .spyOn(api, 'deleteAgentKanbanKnowledge')
      .mockResolvedValue({ ok: true } as Awaited<ReturnType<typeof api.deleteAgentKanbanKnowledge>>)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      knowledges: [
        {
          id: 'k_1',
          kanban_id: 'wi_kanban',
          file_path: '/home/me/spec.md',
          label: 'Spec',
          content: '',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    q<HTMLButtonElement>('kanban-agent-knowledge-remove-k_1').click()
    await flushPromises()
    expect(deleteSpy).toHaveBeenCalledWith('wi_kanban', 'k_1')
    expect(maybeQ('kanban-agent-knowledge-row-k_1')).toBeNull()
  })

  it('renders existing system-prompt rows with title and edit/remove buttons', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      system_prompts: [
        {
          id: 'p_1',
          kanban_id: 'wi_kanban',
          title: 'Persona',
          content: 'You are a senior engineer.',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    const row = q('kanban-agent-system-prompt-row-p_1')
    expect(row.textContent).toContain('Persona')
    expect(maybeQ('kanban-agent-system-prompt-edit-p_1')).not.toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-remove-p_1')).not.toBeNull()
  })

  it('calls deleteAgentKanbanSystemPrompt when the remove button is clicked', async () => {
    const deleteSpy = vi
      .spyOn(api, 'deleteAgentKanbanSystemPrompt')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.deleteAgentKanbanSystemPrompt>>)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      system_prompts: [
        {
          id: 'p_1',
          kanban_id: 'wi_kanban',
          title: 'Persona',
          content: 'You are a senior engineer.',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    q<HTMLButtonElement>('kanban-agent-system-prompt-remove-p_1').click()
    await flushPromises()
    expect(deleteSpy).toHaveBeenCalledWith('wi_kanban', 'p_1')
    expect(maybeQ('kanban-agent-system-prompt-row-p_1')).toBeNull()
  })

  it('opens the knowledge-add sub-dialog when the + Add button is clicked', async () => {
    mountPanel()
    await flushPromises()
    q<HTMLButtonElement>('kanban-agent-knowledge-add').click()
    await nextTick()
    expect(maybeQ('agent-knowledge-dialog')).not.toBeNull()
  })

  it('opens the system-prompt-add sub-dialog when the + Add button is clicked', async () => {
    mountPanel()
    await flushPromises()
    q<HTMLButtonElement>('kanban-agent-system-prompt-add').click()
    await nextTick()
    expect(maybeQ('agent-system-prompt-dialog')).not.toBeNull()
  })

  it('shows the unconfigured empty state (no knowledge/system-prompt rows) when no agent_kanban row exists', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-knowledge-unconfigured')).not.toBeNull()
    // Tells the user to bootstrap via the Tools tab.
    const body = document.body.textContent ?? ''
    expect(body).toContain('Tools')
  })
})

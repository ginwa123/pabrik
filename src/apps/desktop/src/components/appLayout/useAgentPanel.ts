import { ref, type ComputedRef, type Ref } from 'vue'
import * as api from '../../api'
import type { Workspace, WorkspaceItem } from '../../stores/workspaces'
import type { AgnosticKnowledgeRow } from '../views/AgentView.vue'
import { tryParseErrorBody } from './agentErrors'

type AgentPanelDeps = {
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  activeWorkspace: ComputedRef<Workspace | undefined>
}

export interface UseAgentPanelReturn {
  agentKnowledge: Ref<api.AgentKnowledgeRow[]>
  agentTools: Ref<string[]>
  agentSystemPrompts: Ref<api.AgentSystemPromptRow[]>
  agentDataLoading: Ref<boolean>
  maybeLoadAgentData: () => void
  agentKnowledgeDialogOpen: Ref<boolean>
  agentKnowledgeError: Ref<string | null>
  agentKnowledgeBusy: Ref<boolean>
  handleAgentAddKnowledge: () => Promise<void>
  closeAgentKnowledgeDialog: () => void
  handleAgentKnowledgeCreate: (filePath: string, label: string, content: string) => Promise<void>
  handleAgentRemoveKnowledge: (knowledgeId: string) => Promise<void>
  agentKnowledgeDetailOpen: Ref<boolean>
  agentKnowledgeDetailRow: Ref<api.AgentKnowledgeRow | null>
  agentKnowledgeDetailBusy: Ref<boolean>
  agentKnowledgeDetailError: Ref<string | null>
  handleAgentEditKnowledge: (row: AgnosticKnowledgeRow) => void
  closeAgentKnowledgeDetailDialog: () => void
  handleAgentKnowledgeSave: (
    knowledgeId: string,
    updates: { label: string; file_path?: string; content?: string },
  ) => Promise<void>
}

/** Agent Mode state: the GET /agent bundle plus the knowledge add / edit dialogs. */
export function useAgentPanel(deps: AgentPanelDeps): UseAgentPanelReturn {
  const { activeWorkspaceItem, activeWorkspace } = deps

// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0): agent chat inline view.
const agentKnowledge = ref<api.AgentKnowledgeRow[]>([])
const agentTools = ref<string[]>([])
// Agent system prompts (Migration 080) — same plain-ref pattern as knowledge above; the GET /agent bundle carries them in one round-trip.
const agentSystemPrompts = ref<api.AgentSystemPromptRow[]>([])

// True while `loadAgentData` is in flight.
const agentDataLoading = ref(false)

// FIX (agent-tools-fetch-on-view): the previous code only fetched `agentTools` inside the `activeTask` watcher.
async function loadAgentData(agentItemId: string) {
  agentDataLoading.value = true
  try {
    const wsId = activeWorkspace?.value?.id
    if (!wsId) return
    const data = await api.getAgent(wsId, agentItemId)
    agentKnowledge.value = data.knowledge
    agentTools.value = data.tools
    // Migration 080: the bundle now carries system_prompts too.
    agentSystemPrompts.value = data.system_prompts ?? []
  } catch (e) {
    console.error('[AppLayout] failed to load agent:', e)
  } finally {
    // Cleared on BOTH paths — a failed fetch must not park the skeleton forever (the panels fall back to their empty states, which is the honest answer when the …
    agentDataLoading.value = false
  }
}

// Load agent bundle for agent items (replaces the old item-id watcher).
let lastAgentLoadItemId: string | null = null
const maybeLoadAgentData = () => {
  const id = activeWorkspaceItem.value?.id
  if (!id || activeWorkspaceItem.value?.item_type !== 'agent') return
  // Fire once per item id (replicates the old watcher, which only fired on change): setup + onMounted + pump must not triple-fetch.
  if (id === lastAgentLoadItemId) return
  lastAgentLoadItemId = id
  // Fire-and-forget; loadAgentData assigns the refs itself.
  void loadAgentData(id)
}
// Setup-time call (replicates the old immediate watcher): the setup-time restore above already set the item for direct landings.
maybeLoadAgentData()

// Agent knowledge dialog open state + last-targeted agent id.
const agentKnowledgeDialogOpen = ref(false)
const agentKnowledgeError = ref<string | null>(null)
const agentKnowledgeBusy = ref(false)

function openAgentKnowledgeDialog() {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentKnowledgeError.value = null
  agentKnowledgeDialogOpen.value = true
}

async function handleAgentAddKnowledge() {
  // v1.1 wiring: open the AgentKnowledgeDialog.
  openAgentKnowledgeDialog()
}

function closeAgentKnowledgeDialog() {
  agentKnowledgeDialogOpen.value = false
  agentKnowledgeError.value = null
}

async function handleAgentKnowledgeCreate(filePath: string, label: string, content: string) {
  const wsId = activeWorkspace?.value?.id
  const itemId = activeWorkspaceItem.value?.id
  if (!wsId || !itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentKnowledgeBusy.value = true
  agentKnowledgeError.value = null
  try {
    // The backend expects `agentId` (== workspace_item_id for agents) on `POST /api/agents/:agentId/knowledge`.
    const newRow = await api.addAgentKnowledge(itemId, filePath, label, content)
    // Optimistic append — the GET /agent response won't be re-fetched until the user navigates away and back.
    agentKnowledge.value = [...agentKnowledge.value, newRow]
    closeAgentKnowledgeDialog()
  } catch (e) {
    agentKnowledgeError.value = e instanceof Error ? e.message : 'Failed to add knowledge'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentKnowledgeBusy.value = false
  }
}

async function handleAgentRemoveKnowledge(knowledgeId: string) {
  const wsId = activeWorkspace?.value?.id
  const itemId = activeWorkspaceItem.value?.id
  if (!wsId || !itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  // Optimistic remove + restore on failure.
  const previous = agentKnowledge.value
  agentKnowledge.value = previous.filter((k) => k.id !== knowledgeId)
  try {
    await api.deleteAgentKnowledge(itemId, knowledgeId)
  } catch (e) {
    // Restore the row so the user can retry.
    agentKnowledge.value = previous
    console.error('[AppLayout] failed to remove knowledge:', e)
  }
}

// Agent knowledge EDIT dialog (plan 2026-08-22-agent-mode-ui-ux, A2).
const agentKnowledgeDetailOpen = ref(false)
const agentKnowledgeDetailRow = ref<api.AgentKnowledgeRow | null>(null)
const agentKnowledgeDetailBusy = ref(false)
const agentKnowledgeDetailError = ref<string | null>(null)

function handleAgentEditKnowledge(row: AgnosticKnowledgeRow) {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentKnowledgeDetailRow.value = row as api.AgentKnowledgeRow
  agentKnowledgeDetailError.value = null
  agentKnowledgeDetailOpen.value = true
}

function closeAgentKnowledgeDetailDialog() {
  agentKnowledgeDetailOpen.value = false
  agentKnowledgeDetailError.value = null
}

async function handleAgentKnowledgeSave(
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentKnowledgeDetailBusy.value = true
  agentKnowledgeDetailError.value = null
  try {
    // The dialog always sends both source fields (file_path + content, one of them '') so a File↔Text mode switch flips the row cleanly.
    const updated = await api.updateAgentKnowledge(itemId, knowledgeId, updates)
    // Replace in place so list order is preserved.
    agentKnowledge.value = agentKnowledge.value.map((k) => (k.id === knowledgeId ? updated : k))
    closeAgentKnowledgeDetailDialog()
  } catch (e) {
    // ApiError carries the backend's JSON body (e.g. {"error":"..."}).
    agentKnowledgeDetailError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update knowledge'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentKnowledgeDetailBusy.value = false
  }
}
  return {
    agentKnowledge,
    agentTools,
    agentSystemPrompts,
    agentDataLoading,
    maybeLoadAgentData,
    agentKnowledgeDialogOpen,
    agentKnowledgeError,
    agentKnowledgeBusy,
    handleAgentAddKnowledge,
    closeAgentKnowledgeDialog,
    handleAgentKnowledgeCreate,
    handleAgentRemoveKnowledge,
    agentKnowledgeDetailOpen,
    agentKnowledgeDetailRow,
    agentKnowledgeDetailBusy,
    agentKnowledgeDetailError,
    handleAgentEditKnowledge,
    closeAgentKnowledgeDetailDialog,
    handleAgentKnowledgeSave,
  }
}

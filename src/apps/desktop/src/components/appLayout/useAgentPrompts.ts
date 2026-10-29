import { ref, type ComputedRef, type Ref } from 'vue'
import * as api from '../../api'
import { buildToggle } from '../../stores/agentToolToggle'
import type { WorkspaceItem } from '../../stores/workspaces'
import type { AgnosticSystemPromptRow } from '../views/AgentView.vue'
import { tryParseErrorBody } from './agentErrors'

type AgentPromptsDeps = {
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  agentTools: Ref<string[]>
  agentSystemPrompts: Ref<api.AgentSystemPromptRow[]>
}

export interface UseAgentPromptsReturn {
  agentSystemPromptDialogOpen: Ref<boolean>
  agentSystemPromptRow: Ref<api.AgentSystemPromptRow | null>
  agentSystemPromptBusy: Ref<boolean>
  agentSystemPromptError: Ref<string | null>
  handleAgentAddSystemPrompt: () => void
  handleAgentEditSystemPrompt: (row: AgnosticSystemPromptRow) => void
  closeAgentSystemPromptDialog: () => void
  handleAgentSystemPromptCreate: (title: string, content: string) => Promise<void>
  handleAgentSystemPromptSave: (
    promptId: string,
    updates: { title: string; content: string },
  ) => Promise<void>
  handleAgentRemoveSystemPrompt: (promptId: string) => Promise<void>
  handleAgentToggleTool: (toolName: string, enabled: boolean) => Promise<void>
  handleAgentToggleToolsBulk: (toolNames: string[], enabled: boolean) => Promise<void>
}

/** Agent Mode system prompts (Migration 080) and the tool toggles AgentView's panels drive. */
export function useAgentPrompts(deps: AgentPromptsDeps): UseAgentPromptsReturn {
  const { activeWorkspaceItem, agentTools, agentSystemPrompts } = deps

// ─── Agent System Prompt dialog (Migration 080, plan 2026-08-21-agent-system-prompt) ──
// Same open/busy/error pattern as the knowledge dialogs above. One
// dialog serves add (row=null) and edit (row set).
const agentSystemPromptDialogOpen = ref(false)
const agentSystemPromptRow = ref<api.AgentSystemPromptRow | null>(null)
const agentSystemPromptBusy = ref(false)
const agentSystemPromptError = ref<string | null>(null)

function handleAgentAddSystemPrompt() {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentSystemPromptRow.value = null
  agentSystemPromptError.value = null
  agentSystemPromptDialogOpen.value = true
}

function handleAgentEditSystemPrompt(row: AgnosticSystemPromptRow) {
  if (!activeWorkspaceItem.value || activeWorkspaceItem.value.item_type !== 'agent') return
  agentSystemPromptRow.value = row as api.AgentSystemPromptRow
  agentSystemPromptError.value = null
  agentSystemPromptDialogOpen.value = true
}

function closeAgentSystemPromptDialog() {
  agentSystemPromptDialogOpen.value = false
  agentSystemPromptError.value = null
}

async function handleAgentSystemPromptCreate(title: string, content: string) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentSystemPromptBusy.value = true
  agentSystemPromptError.value = null
  try {
    // agents.id == workspace_item_id (Migration 076 spec D3).
    const newRow = await api.addAgentSystemPrompt(itemId, title, content)
    // Optimistic append — same rationale as knowledge create.
    agentSystemPrompts.value = [...agentSystemPrompts.value, newRow]
    closeAgentSystemPromptDialog()
  } catch (e) {
    // Surface the backend's specific error message when available.
    agentSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to add system prompt'
    // Keep the dialog open so the user can see + retry.
  } finally {
    agentSystemPromptBusy.value = false
  }
}

async function handleAgentSystemPromptSave(
  promptId: string,
  updates: { title: string; content: string },
) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  agentSystemPromptBusy.value = true
  agentSystemPromptError.value = null
  try {
    const updated = await api.updateAgentSystemPrompt(itemId, promptId, updates)
    // Replace in place so list order is preserved.
    agentSystemPrompts.value = agentSystemPrompts.value.map((p) =>
      p.id === promptId ? updated : p,
    )
    closeAgentSystemPromptDialog()
  } catch (e) {
    agentSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update system prompt'
  } finally {
    agentSystemPromptBusy.value = false
  }
}

async function handleAgentRemoveSystemPrompt(promptId: string) {
  const itemId = activeWorkspaceItem.value?.id
  if (!itemId || activeWorkspaceItem.value?.item_type !== 'agent') return

  // Optimistic remove + restore on failure.
  const previous = agentSystemPrompts.value
  agentSystemPrompts.value = previous.filter((p) => p.id !== promptId)
  try {
    await api.deleteAgentSystemPrompt(itemId, promptId)
  } catch (e) {
    // Restore the row so the user can retry.
    agentSystemPrompts.value = previous
    console.error('[AppLayout] failed to remove system prompt:', e)
  }
}

async function handleAgentToggleTool(toolName: string, enabled: boolean) {
  if (!activeWorkspaceItem.value) return
  const agentId = activeWorkspaceItem.value.id
  const { nextLocal, serverPromise } = buildToggle(agentTools.value, toolName, enabled, agentId, {
    enableAgentTool: api.enableAgentTool,
    disableAgentTool: api.disableAgentTool,
    refetchAgentTools: async (id) => {
      const data = await api.getAgentTools(id)
      return data.tools
    },
  })
  // Optimistic update.
  agentTools.value = nextLocal
  const out = await serverPromise
  if ('error' in out) {
    // Revert + log.
    agentTools.value = enabled
      ? agentTools.value.filter((n) => n !== toolName)
      : [...agentTools.value, toolName]
    console.error('[AppLayout] toggle tool failed:', out.error)
    return
  }
  // Canonical state from server.
  agentTools.value = out.canonical
}

/** Bulk-toggle multiple tools at once (fired by AgentView's "Select all" / "Clear" buttons in the
 * Tools panel). */
async function handleAgentToggleToolsBulk(toolNames: string[], enabled: boolean) {
  if (!activeWorkspaceItem.value) return
  const agentId = activeWorkspaceItem.value.id
  if (toolNames.length === 0) return

  // Optimistic apply.
  const set = new Set(agentTools.value)
  for (const n of toolNames) {
    if (enabled) set.add(n)
    else set.delete(n)
  }
  agentTools.value = Array.from(set)

  try {
    const ops = toolNames.map(async (n) => {
      try {
        if (enabled) await api.enableAgentTool(agentId, n)
        else await api.disableAgentTool(agentId, n)
        return { name: n, ok: true as const }
      } catch (e) {
        return { name: n, ok: false as const, error: e }
      }
    })
    const results = await Promise.all(ops)
    const failures = results.filter((r) => !r.ok)
    if (failures.length > 0) {
      console.error('[AppLayout] bulk toggle: some tools failed:', failures)
    }
    // Re-fetch the canonical list so partial successes + races collapse
    // into one coherent view. Cheap (one GET).
    const data = await api.getAgentTools(agentId)
    agentTools.value = data.tools
  } catch (e) {
    console.error('[AppLayout] bulk toggle failed:', e)
  }
}

  return {
    agentSystemPromptDialogOpen,
    agentSystemPromptRow,
    agentSystemPromptBusy,
    agentSystemPromptError,
    handleAgentAddSystemPrompt,
    handleAgentEditSystemPrompt,
    closeAgentSystemPromptDialog,
    handleAgentSystemPromptCreate,
    handleAgentSystemPromptSave,
    handleAgentRemoveSystemPrompt,
    handleAgentToggleTool,
    handleAgentToggleToolsBulk,
  }
}

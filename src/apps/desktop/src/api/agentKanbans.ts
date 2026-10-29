import { ApiError, apiFetch } from './core'

// ─── Agent-Kanbans Mirror (Migration 081) ─────────────────────────────── Mirrors the Agent Mode
// block above onto kanban boards. The config row (`agent_kanbans`) is OPT-IN — `getAgentKanban`
// resolves to `null` (silently, no error toast) when the board has no config yet.
export interface AgentKanban {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentKanbanKnowledgeRow {
  id: string
  kanban_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentKanbanSystemPromptRow {
  id: string
  kanban_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentKanbanToolRow {
  id: string
  kanban_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/**  * Get the agent-kanbans config + children for a kanban workspace_item. Returns null (silent) on 404
 * "not configured" — an unconfigured board is an expected state, not an error worth surfacing. GET
 * /api/workspaces/:workspaceId/items/:itemId/agent_kanban */
export async function getAgentKanban(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent_kanban: AgentKanban
  knowledges: AgentKanbanKnowledgeRow[]
  tools: string[]
  system_prompts: AgentKanbanSystemPromptRow[]
} | null> {
  try {
    return await apiFetch<{
      agent_kanban: AgentKanban
      knowledges: AgentKanbanKnowledgeRow[]
      tools: string[]
      system_prompts: AgentKanbanSystemPromptRow[]
    }>(`/workspaces/${workspaceId}/items/${itemId}/agent_kanban`, { silent: true })
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Update the agent-kanbans config's description.
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_kanban */
export async function updateAgentKanban(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent_kanban: AgentKanban }> {
  return await apiFetch<{ agent_kanban: AgentKanban }>(
    `/workspaces/${workspaceId}/items/${itemId}/agent_kanban`,
    { method: 'PATCH', body: { description } },
  )
}

/** Add a knowledge entry to a board's config — file path XOR inline text.
 * POST /api/agent-kanbans/:kanbanId/knowledge */
export async function addAgentKanbanKnowledge(
  kanbanId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentKanbanKnowledgeRow> {
  return await apiFetch<AgentKanbanKnowledgeRow>(`/agent-kanbans/${kanbanId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentKanbanKnowledge(
  kanbanId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentKanbanKnowledgeRow> {
  return await apiFetch<AgentKanbanKnowledgeRow>(
    `/agent-kanbans/${kanbanId}/knowledge/${knowledgeId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentKanbanKnowledge(
  kanbanId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKanbanKnowledge(
  kanbanId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Add a named system-prompt block to a board's config. `content` required; `title` optional. POST
 * /api/agent-kanbans/:kanbanId/system_prompt */
export async function addAgentKanbanSystemPrompt(
  kanbanId: string,
  title: string,
  content: string,
): Promise<AgentKanbanSystemPromptRow> {
  return await apiFetch<AgentKanbanSystemPromptRow>(`/agent-kanbans/${kanbanId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentKanbanSystemPrompt(
  kanbanId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentKanbanSystemPromptRow> {
  return await apiFetch<AgentKanbanSystemPromptRow>(
    `/agent-kanbans/${kanbanId}/system_prompt/${promptId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentKanbanSystemPrompt(
  kanbanId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKanbanSystemPrompts(
  kanbanId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Get the enabled tool names for a board's config. Empty array = no tools configured for this
 * board. GET /api/agent-kanbans/:kanbanId/tools */
export async function getAgentKanbanTools(kanbanId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-kanbans/${kanbanId}/tools`)
}

/**  * Enable a tool for the board. Backend validates against the registry (400 if unknown) and returns
 * 409 on duplicate. POST /api/agent-kanbans/:kanbanId/tools */
export async function enableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<AgentKanbanToolRow> {
  return await apiFetch<AgentKanbanToolRow>(`/agent-kanbans/${kanbanId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/** Disable a tool for the board (deletes the row).
 * DELETE /api/agent-kanbans/:kanbanId/tools/:toolName */
export async function disableAgentKanbanTool(
  kanbanId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-kanbans/${kanbanId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

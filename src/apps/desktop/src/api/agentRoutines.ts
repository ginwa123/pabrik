import { ApiError, apiFetch } from './client'

// ─── Agent-Routines Mirror (Migration 088) ───────────────────────────── Mirrors the Agent-Kanbans
// block above onto routine items.
export interface AgentRoutine {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentRoutineKnowledgeRow {
  id: string
  routine_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentRoutineSystemPromptRow {
  id: string
  routine_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentRoutineToolRow {
  id: string
  routine_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/**  * Get the agent-routines config + children for a routine workspace_item. Returns null (silent) on
 * 404 "not configured" — an unconfigured routine is an expected state, not an error worth
 * surfacing. GET /api/workspaces/:workspaceId/items/:itemId/agent_routine */
export async function getAgentRoutine(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent_routine: AgentRoutine
  knowledges: AgentRoutineKnowledgeRow[]
  tools: string[]
  system_prompts: AgentRoutineSystemPromptRow[]
} | null> {
  try {
    return await apiFetch<{
      agent_routine: AgentRoutine
      knowledges: AgentRoutineKnowledgeRow[]
      tools: string[]
      system_prompts: AgentRoutineSystemPromptRow[]
    }>(`/workspaces/${workspaceId}/items/${itemId}/agent_routine`, { silent: true })
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Update the agent-routines config's description.
 * PATCH /api/workspaces/:workspaceId/items/:itemId/agent_routine */
export async function updateAgentRoutine(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent_routine: AgentRoutine }> {
  return await apiFetch<{ agent_routine: AgentRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/agent_routine`,
    { method: 'PATCH', body: { description } },
  )
}

/** Add a knowledge entry to a routine's config — file path XOR inline text.
 * POST /api/agent-routines/:routineId/knowledge */
export async function addAgentRoutineKnowledge(
  routineId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentRoutineKnowledgeRow> {
  return await apiFetch<AgentRoutineKnowledgeRow>(`/agent-routines/${routineId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentRoutineKnowledge(
  routineId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentRoutineKnowledgeRow> {
  return await apiFetch<AgentRoutineKnowledgeRow>(
    `/agent-routines/${routineId}/knowledge/${knowledgeId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentRoutineKnowledge(
  routineId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentRoutineKnowledge(
  routineId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Add a named system-prompt block to a routine's config. `content` required; `title` optional. POST
 * /api/agent-routines/:routineId/system_prompt */
export async function addAgentRoutineSystemPrompt(
  routineId: string,
  title: string,
  content: string,
): Promise<AgentRoutineSystemPromptRow> {
  return await apiFetch<AgentRoutineSystemPromptRow>(`/agent-routines/${routineId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentRoutineSystemPrompt(
  routineId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentRoutineSystemPromptRow> {
  return await apiFetch<AgentRoutineSystemPromptRow>(
    `/agent-routines/${routineId}/system_prompt/${promptId}`,
    { method: 'PATCH', body: updates },
  )
}

export async function deleteAgentRoutineSystemPrompt(
  routineId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentRoutineSystemPrompts(
  routineId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/**  * Get the enabled tool names for a routine's config. Empty array = no tools configured for this
 * routine. GET /api/agent-routines/:routineId/tools */
export async function getAgentRoutineTools(routineId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agent-routines/${routineId}/tools`)
}

/**  * Enable a tool for the routine. Backend validates against the registry (400 if unknown) and
 * returns 409 on duplicate. POST /api/agent-routines/:routineId/tools */
export async function enableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<AgentRoutineToolRow> {
  return await apiFetch<AgentRoutineToolRow>(`/agent-routines/${routineId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/** Disable a tool for the routine (deletes the row).
 * DELETE /api/agent-routines/:routineId/tools/:toolName */
export async function disableAgentRoutineTool(
  routineId: string,
  toolName: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agent-routines/${routineId}/tools/${toolName}`, {
    method: 'DELETE',
  })
}

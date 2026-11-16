import { apiFetch } from './client'
import type { WorkspaceItem } from './workspaces'

// `uploadTaskAttachment` REMOVED 2026-08-06 (kanban-image-urls-column plan).
export interface Agent {
  id: string
  workspace_item_id: string
  description: string
  created_at: string
  updated_at: string
}

export interface AgentKnowledgeRow {
  id: string
  agent_id: string
  file_path: string
  label: string
  /** Inline manual text ('' = file-backed row). */
  content: string
  position: number
  created_at: string
  updated_at: string
}

export interface AgentToolRow {
  id: string
  agent_id: string
  tool_name: string
  enabled: number
  created_at: string
}

/** One parameter of a registry entry's schema. */
export interface AgentRegistryParameter {
  name: string
  /** JSON Schema type, e.g. 'string' | 'array' | 'number' | 'boolean'. */
  type: string
  /** True when the JSON schema lists it in `required`. */
  required: boolean
}

/** Where a registry entry comes from: the compiled-in registry, or an MCP server. */
export type AgentRegistryKind = 'builtin' | 'mcp'

export interface AgentRegistryEntry {
  name: string
  description: string
  /** The tool's full parameter list, in declaration order. */
  parameters?: AgentRegistryParameter[]
  /** `mcp` when a configured MCP server advertised the tool, `builtin` for one compiled into the runtime. */
  kind?: AgentRegistryKind
}

/** Create a new agent workspace item. */
export async function createAgent(
  workspaceId: string,
  name: string,
  path: string,
): Promise<{ item: WorkspaceItem; agent: Agent }> {
  return await apiFetch<{ item: WorkspaceItem; agent: Agent }>(
    `/workspaces/${workspaceId}/items/agent`,
    { method: 'POST', body: { name, path } },
  )
}

/** Get agent + knowledge + tools + system prompts for a workspace_item. */
export async function getAgent(
  workspaceId: string,
  itemId: string,
): Promise<{
  agent: Agent
  knowledge: AgentKnowledgeRow[]
  tools: string[]
  /** Migration 080 — per-agent named prompt blocks, position DESC. */
  system_prompts: AgentSystemPromptRow[]
}> {
  return await apiFetch<{
    agent: Agent
    knowledge: AgentKnowledgeRow[]
    tools: string[]
    system_prompts: AgentSystemPromptRow[]
  }>(`/workspaces/${workspaceId}/items/${itemId}/agent`)
}

/** Update an agent's description. */
export async function updateAgent(
  workspaceId: string,
  itemId: string,
  description: string,
): Promise<{ agent: Agent }> {
  return await apiFetch<{ agent: Agent }>(`/workspaces/${workspaceId}/items/${itemId}/agent`, {
    method: 'PATCH',
    body: { description },
  })
}

// ===================================================================== Workspace routines (Migration 084) — first-class `item_type='routine'` items beside …
export interface WorkspaceRoutine {
  id: string
  workspace_item_id: string
  description: string
  /** The agent prompt fired on each tick. */
  instruction: string
  /** 5-field cron. '' = manual-run only (no auto-fire). */
  schedule: string
  /** The profile name this routine fires under. '' = the backend's active-profile cascade. */
  selected_profile_model: string
  cwd: string
  enabled: boolean
  last_run_at: string
  /** '' when manual-only or disabled. */
  next_run_at: string
  last_status: string
  last_error: string
  created_at: string
  updated_at: string
}

/** Create a new routine workspace item. */
export async function createRoutineItem(
  workspaceId: string,
  name: string,
  path: string,
  opts?: {
    description?: string
    instruction?: string
    schedule?: string
    enabled?: boolean
  },
): Promise<{ item: WorkspaceItem; routine: WorkspaceRoutine }> {
  return await apiFetch<{ item: WorkspaceItem; routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/routine`,
    {
      method: 'POST',
      body: {
        name,
        path,
        description: opts?.description ?? '',
        instruction: opts?.instruction ?? '',
        schedule: opts?.schedule ?? '',
        enabled: opts?.enabled ?? true,
      },
    },
  )
}

/** Get the routine bound to a workspace_item. */
export async function getRoutineItem(
  workspaceId: string,
  itemId: string,
): Promise<{ routine: WorkspaceRoutine }> {
  return await apiFetch<{ routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/routine`,
  )
}

/** Update a routine's description / instruction / schedule / enabled. */
export async function updateRoutineItem(
  workspaceId: string,
  itemId: string,
  data: {
    description?: string
    instruction?: string
    schedule?: string
    selected_profile_model?: string
    cwd?: string
    enabled?: boolean
  },
): Promise<{ routine: WorkspaceRoutine }> {
  return await apiFetch<{ routine: WorkspaceRoutine }>(
    `/workspaces/${workspaceId}/items/${itemId}/routine`,
    { method: 'PATCH', body: data },
  )
}

/** Add a knowledge entry to an agent — either a markdown file path on disk (`filePath`) or inline manual text (`content`). */
export async function addAgentKnowledge(
  agentId: string,
  filePath: string,
  label?: string,
  content?: string,
): Promise<AgentKnowledgeRow> {
  return await apiFetch<AgentKnowledgeRow>(`/agents/${agentId}/knowledge`, {
    method: 'POST',
    body: { file_path: filePath, label: label ?? '', content: content ?? '' },
  })
}

export async function updateAgentKnowledge(
  agentId: string,
  knowledgeId: string,
  updates: { file_path?: string; label?: string; content?: string },
): Promise<AgentKnowledgeRow> {
  return await apiFetch<AgentKnowledgeRow>(`/agents/${agentId}/knowledge/${knowledgeId}`, {
    method: 'PATCH',
    body: updates,
  })
}

export async function deleteAgentKnowledge(
  agentId: string,
  knowledgeId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/knowledge/${knowledgeId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentKnowledge(
  agentId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/knowledge/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

// ─── Agent System Prompt (Migration 080) ────────────────────────────────
export interface AgentSystemPromptRow {
  id: string
  agent_id: string
  title: string
  content: string
  position: number
  created_at: string
  updated_at: string
}

/** Add a named system-prompt block to an agent. */
export async function addAgentSystemPrompt(
  agentId: string,
  title: string,
  content: string,
): Promise<AgentSystemPromptRow> {
  return await apiFetch<AgentSystemPromptRow>(`/agents/${agentId}/system_prompt`, {
    method: 'POST',
    body: { title, content },
  })
}

export async function updateAgentSystemPrompt(
  agentId: string,
  promptId: string,
  updates: { title?: string; content?: string },
): Promise<AgentSystemPromptRow> {
  return await apiFetch<AgentSystemPromptRow>(`/agents/${agentId}/system_prompt/${promptId}`, {
    method: 'PATCH',
    body: updates,
  })
}

export async function deleteAgentSystemPrompt(
  agentId: string,
  promptId: string,
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/system_prompt/${promptId}`, {
    method: 'DELETE',
  })
}

export async function reorderAgentSystemPrompts(
  agentId: string,
  orderedIds: string[],
): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/system_prompt/reorder`, {
    method: 'PATCH',
    body: { ordered_ids: orderedIds },
  })
}

/** Get the canonical tool registry (UNIFIED_TOOL_REGISTRY, single source of truth per spec D4). */
export async function getAgentToolsRegistry(
  opts: { includeMcp?: boolean; workspaceId?: string | null } = {},
): Promise<{ tools: AgentRegistryEntry[] }> {
  const params = new URLSearchParams()
  if (opts.includeMcp) params.set('include_mcp', '1')
  if (opts.workspaceId) params.set('workspace_id', opts.workspaceId)
  const query = params.toString()
  return await apiFetch<{ tools: AgentRegistryEntry[] }>(
    `/agent-tools/registry${query ? `?${query}` : ''}`,
  )
}

/** Get the enabled tool names for an agent. */
export async function getAgentTools(agentId: string): Promise<{ tools: string[] }> {
  return await apiFetch<{ tools: string[] }>(`/agents/${agentId}/tools`)
}

/** Enable a tool for the agent. */
export async function enableAgentTool(agentId: string, toolName: string): Promise<AgentToolRow> {
  return await apiFetch<AgentToolRow>(`/agents/${agentId}/tools`, {
    method: 'POST',
    body: { tool_name: toolName },
  })
}

/** Disable a tool for the agent (deletes the row). */
export async function disableAgentTool(agentId: string, toolName: string): Promise<{ ok: true }> {
  return await apiFetch<{ ok: true }>(`/agents/${agentId}/tools/${toolName}`, { method: 'DELETE' })
}

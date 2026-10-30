import { apiFetch } from './client'

// Update an existing session (selectedAgent, name, isAutoRetryUntilStop). Migration 063 — extends
// the update shape to carry the unattended- mode flag. Pass `isAutoRetryUntilStop: '0'` to disable,
// '1' to enable, or omit to leave unchanged (matches the backend's `len > 0` guard).
export async function updateSession(
  sessionId: string,
  updates: {
    selectedAgent?: string | null
    name?: string
    isAutoRetryUntilStop?: string
  },
): Promise<{
  id: string
  name: string
  status: string
  selected_profile_model: string
  is_auto_retry_until_stop: string
}> {
  return await apiFetch<{
    id: string
    name: string
    status: string
    selected_profile_model: string
    is_auto_retry_until_stop: string
  }>(`/llm/session/${sessionId}`, {
    method: 'PUT',
    body: {
      selected_profile_model: updates.selectedAgent ?? '',
      name: updates.name ?? '',
      is_auto_retry_until_stop: updates.isAutoRetryUntilStop ?? '',
    },
  })
}

// POST /api/llm/session/:session_id/touched — stamp the human-touch column when the user opens a
// chat (clears the amber stale-dot). Contract: body {}, response { success, session_id }.
export async function markSessionTouched(
  sessionId: string,
): Promise<{ success: boolean; session_id: string }> {
  return await apiFetch<{ success: boolean; session_id: string }>(
    `/llm/session/${sessionId}/touched`,
    {
      method: 'POST',
      body: {},
      silent: true,
    },
  )
}

// Migration 104 — pin/unpin a session for the PINNED section above RECENT. Mirrors `pinTask`
// (kanban). The backend bumps `pinned_position` to MAX+1 on pin (lands at bottom) and syncs the
// linked task row when task.id == session_id, so kanban pin buttons stay in sync.
export async function pinSession(
  sessionId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{
    success: boolean
    id: string
    is_pinned: boolean
    pinned_position: number
  }>(`/llm/session/${sessionId}/pin`, {
    method: 'POST',
    body: { is_pinned: isPinned },
  })
}

// Migration 104 — reorder the PINNED section (drag-drop). `orderedIds`
// is the full top-to-bottom display order of pinned session ids.
export async function reorderPinnedSessions(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(`/llm/session/reorder_pinned`, {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

// Session API - Fetch session info including cwd. Lightweight detail read: GET /api/llm/session/:id
// returns the sessions row (cwd, profile, worktree binding, PR binding, ...) with NO message
// payload.
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedAgent?: string
  // Migration 091 — resolved sub-agent name (e.g. "implementator").
  subAgentName?: string
  parentSessionId?: string
  // Bound git worktree path (empty string when no worktree is bound;
  // optional because older sessions predate the set_git_worktree tool).
  git_worktree_cwd?: string
  prUrl?: string
  prProvider?: string
  workspaceId?: string | null
}

// In-flight dedupe: AppLayout + ChatView mount concurrently for the same
// session, so two getSession() calls for one id share a single fetch.
const sessionInflight = new Map<string, Promise<Session | null>>()

export async function getSession(sessionId: string): Promise<Session | null> {
  const pending = sessionInflight.get(sessionId)
  if (pending) return pending
  const task = fetchSessionDetail(sessionId)
  sessionInflight.set(sessionId, task)
  try {
    return await task
  } finally {
    if (sessionInflight.get(sessionId) === task) sessionInflight.delete(sessionId)
  }
}

async function fetchSessionDetail(sessionId: string): Promise<Session | null> {
  try {
    // silent: true — AppLayout.fetchChatSessionCwd falls back to a cached
    // cwd on null, so a toast on 404/5xx would be noise.
    const data = await apiFetch<{
      session_id?: string
      name?: string
      cwd?: string
      created_at?: string
      // 2026-08-07-profile-persist-read — extract the per-session selected profile name.
      selected_profile_model?: string
      sub_agent_name?: string
      parent_session_id?: string
      git_worktree_cwd?: string
      pr_url?: string
      pr_provider?: string
      workspace_id?: string | null
    }>(`/llm/session/${encodeURIComponent(sessionId)}`, { silent: true })
    return {
      sessionId: data.session_id || sessionId,
      cwd: data.cwd || '',
      createdAt: data.created_at || '',
      agent: '',
      sessionName: data.name || '',
      // 2026-08-07-profile-persist-read — pass through the persisted profile name. Empty string (=
      // "no profile set" from the backend's COALESCE-on-NULL) is preserved here; ChatView coerces
      // empty → null.
      selectedAgent: data.selected_profile_model,
      subAgentName: data.sub_agent_name,
      parentSessionId: data.parent_session_id,
      git_worktree_cwd: data.git_worktree_cwd,
      prUrl: data.pr_url,
      prProvider: data.pr_provider,
      workspaceId: data.workspace_id,
    }
  } catch (error) {
    console.error('Failed to get session:', error)
    return null
  }
}

// Owning workspace of a session (plan: 2026-09-22-revamp-ui-chats). `GET
// /api/llm/session/:session_id` resolves via the task link first, then the cwd heuristic, and
// returns `workspace_id` (string) or null when the session belongs to no workspace.
export async function getSessionWorkspaceId(sessionId: string): Promise<string | null> {
  if (!sessionId) return null
  try {
    const data = await apiFetch<{ workspace_id?: string | null }>(`/llm/session/${sessionId}`, {
      silent: true,
    })
    return typeof data.workspace_id === 'string' && data.workspace_id.length > 0
      ? data.workspace_id
      : null
  } catch {
    return null
  }
}

// Compact chat session history
export async function compactSession(
  sessionId: string,
): Promise<{ success: boolean; message?: string }> {
  try {
    return await apiFetch<{ success: boolean; message?: string }>(`/session/${sessionId}/compact`, {
      method: 'POST',
    })
  } catch (error) {
    console.error('Failed to compact session:', error)
    return { success: false, message: 'Failed to compact session' }
  }
}

/** Stop/cancel a running LLM session by flipping the worker's `cancelled` flag in the DB. The
 * backend handler (`sessionStopHandler` in `src/ai_workflow/tui/ http_handlers/session_stop.zig`)
 * runs `llm_history.cancelSession` which sets `UPDATE worker SET cancelled = 1 WHERE id = ?`. */
export async function answerAskUser(
  sessionId: string,
  body: {
    question_id?: string
    tool_call_id?: string
    answer?: string
    skip?: boolean
  },
): Promise<{ success: boolean; status?: string; answer?: string; resumed?: boolean }> {
  try {
    return await apiFetch<{ success: boolean; status: string; answer: string; resumed: boolean }>(
      `/llm/session/${sessionId}/answer`,
      { method: 'POST', body },
    )
  } catch (error) {
    // The card renders a Retry affordance; the question row stays `pending`
    // server-side (the endpoint never resumes a run whose answer did not
    // land first), so a retry is safe.
    console.error('Failed to answer ask_user question:', error)
    return { success: false }
  }
}

export async function stopSession(
  sessionId: string,
): Promise<{ success: boolean; session_id?: string }> {
  try {
    return await apiFetch<{ success: boolean; session_id: string }>(
      `/llm/session/${sessionId}/stop`,
      { method: 'POST' },
    )
  } catch (error) {
    console.error('Failed to stop session:', error)
    return { success: false }
  }
}

// Worker API
export interface Worker {
  id: string
  session_id: string
  working_directory: string | null
  /** Unix SECONDS of the last heartbeat, as a numeric string. The backend selects
   * `w.last_activity_nano AS last_activity` and every `Row.values` entry is a `[]u8`, so the column
   * is serialised as a JSON string even though the underlying column is INTEGER. */
  last_activity: string | null
  last_activity_description: string | null
  created_at: string | null
  status: string
  is_running: boolean
  queue_count: number
}

export async function getWorkers(
  status?: string,
  limit = 50,
  sessionId?: string,
): Promise<{ workers: Worker[]; count: number }> {
  const params = new URLSearchParams({ limit: limit.toString() })
  if (status) params.set('status', status)
  if (sessionId) params.set('session_id', sessionId)
  return await apiFetch<{ workers: Worker[]; count: number }>(`/workers?${params}`)
}

// GET queued messages
export interface QueuedMessage {
  id: string
  message: string
}

export async function getQueuedMessages(sessionId: string): Promise<{
  messages: QueuedMessage[]
  count: number
}> {
  return await apiFetch<{ messages: QueuedMessage[]; count: number }>(
    `/llm/session/${sessionId}/queue_messages`,
  )
}

// 2026-09-02 stream-resume-on-reselect (task_1787673548905_0) — in-flight stream snapshot.
export interface StreamSnapshot {
  active: boolean
  content: string
}

export async function getStreamSnapshot(sessionId: string): Promise<StreamSnapshot> {
  return await apiFetch<StreamSnapshot>(`/llm/session/${sessionId}/stream`)
}

// 2026-09-04 spawn-subagent-refresh-persist (task_1788505292766_1) — live spawn-batch snapshot.
export interface SubAgentProgressSnapshotRow {
  agent_name: string
  status: 'launched' | 'completed' | 'failed'
  agent_index: number
  total_agents: number
  /** "" when the sub-agent session is not yet known (frontend
   * normalizes to undefined, same as the omitted live-SSE field). */
  subagent_session_id: string
  elapsed_ms: number
}

export interface SubAgentProgressSnapshot {
  tool_call_id: string
  progress: SubAgentProgressSnapshotRow[]
}

export async function getSubAgentProgress(toolCallId: string): Promise<SubAgentProgressSnapshot> {
  return await apiFetch<SubAgentProgressSnapshot>(
    `/subagent/progress/${encodeURIComponent(toolCallId)}`,
  )
}

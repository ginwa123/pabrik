import type { Chat } from './chatHistory'
import { apiFetch } from './client'

/** The session list is the one call whose cost grows with the page it returns, so it gets more
 * than `apiFetch`'s 15s default before a slow-but-healthy backend reads as "no chats". */
export const SESSION_LIST_TIMEOUT_MS = 60_000

// List all chat sessions with pagination
export async function getChats(
  sortBy: 'created_at' | 'updated_at' | 'session_name' | 'agent' = 'created_at',
  direction: 'asc' | 'desc' = 'desc',
  limit: number = 10,
  cursor?: string,
  // Workspace scope (plan: 2026-09-22-revamp-ui-chats). When set, the backend returns only that
  // workspace's sessions (task-linked + cwd-matched); empty/unknown → empty list (fail-closed).
  // Omitted → global list (back-compat for non-scoped callers).
  workspaceId?: string,
): Promise<{
  sessions: Chat[]
  has_more: boolean
  next_cursor: string | null
  total: number
  /** True when this empty list is a failed request, not a scope with no sessions. */
  failed?: boolean
}> {
  try {
    const params = new URLSearchParams({
      sort_by: sortBy,
      direction: direction,
      limit: limit.toString(),
    })
    if (cursor) {
      params.set('cursor', cursor)
    }
    if (workspaceId) {
      params.set('workspace_id', workspaceId)
    }
    const data = await apiFetch<{
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      sessions: any[]
      has_more?: boolean
      next_cursor?: string | null
      total?: number
    }>(`/llm/session?${params}`, { timeoutMs: SESSION_LIST_TIMEOUT_MS })

    // Fix: handle "undefined" or missing session_id in each session
    if (data.sessions && Array.isArray(data.sessions)) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
      data.sessions = data.sessions.map((session: any) => {
        const sessionId = session.session_id || session.id
        if (!sessionId || sessionId === 'undefined' || sessionId === 'null') {
          // Generate proper session ID for invalid entries
          const timestamp = new Date()
            .toISOString()
            .replace(/[:-]/g, '')
            .replace('T', '_')
            .replace(/\.\d{3}Z$/, '')
          return {
            session_id: `session_${timestamp}`,
            session_name: session.session_name || session.name || 'New Session',
            status: session.status || 'active',
            created_at: session.created_at || null,
            updated_at: session.updated_at || null,
            cwd: session.cwd || '',
          }
        }
        return {
          session_id: sessionId,
          session_name: session.session_name || session.name || 'New Session',
          status: session.status || 'active',
          created_at: session.created_at || null,
          updated_at: session.updated_at || null,
          cwd: session.cwd || '',
          selected_profile_model: session.selected_profile_model || '',
          sub_agent_name: session.sub_agent_name || '',
          parent_session_id: session.parent_session_id || '',
          // Sidebar git badge — forward the bound worktree path and the per-request resolved branch
          // ("" = no badge). Empty string when absent so the ChatsList `v-if` is a defined check
          // (NOT undefined).
          git_worktree_cwd: session.git_worktree_cwd || '',
          git_branch: session.git_branch || '',
          // Migration 063 — default to "0" (off) when omitted so the
          // ChatsList badge condition `=== '1'` is a defined check.
          // Matches the SQL COALESCE default in llm_history.zig.
          is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
          // Migration 082 — forward the chat-side stamp. Empty string
          // when absent so the ChatsList `?? updated_at` fallback is
          // a defined check (NOT undefined).
          last_human_touched_at: session.last_human_touched_at || '',
          // Migration 104 — pinned sessions. Boolean on the wire;
          // default false so legacy caches read as unpinned.
          is_pinned: session.is_pinned ?? false,
          pinned_position: session.pinned_position ?? 0,
          last_finish_reason: session.last_finish_reason || '',
          // NOT `?? false`: a legacy cache row with no field must read
          // as "no badge", not "reviewed".
          needs_human_review: session.needs_human_review ?? undefined,
        }
      })
    }

    return {
      sessions: data.sessions || [],
      has_more: data.has_more || false,
      next_cursor: data.next_cursor || null,
      total: data.total || 0,
    }
  } catch (e) {
    // The empty-list shape is a deliberate contract (callers render an empty section instead of
    // crashing). `failed` is what keeps a failed request from being read as "this scope has no
    // sessions" — a caller that ignores it behaves exactly as before.
    console.error('getChats failed; returning an empty list', e)
    return { sessions: [], has_more: false, next_cursor: null, total: 0, failed: true }
  }
}

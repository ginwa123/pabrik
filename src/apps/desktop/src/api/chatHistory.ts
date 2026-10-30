import { Cause, Data, Effect } from 'effect'
import { describeCause } from '../helpers/effectRuntime'
import { apiFetch } from './client'

// Chat API - Zig Backend Integration (Zig backend calls LLM backend internally)
export interface Chat {
  session_id: string
  session_name?: string
  status?: string
  selected_profile_model?: string
  sub_agent_name?: string
  parent_session_id?: string
  cwd?: string
  /// Bound git worktree path ("" = none). The sidebar shows the
  /// kanban-style branch badge when `git_branch` is non-empty and
  /// uses this path as the tooltip + PR-status lookup cwd.
  git_worktree_cwd?: string
  /// Current git branch for the effective cwd ("" / absent = no
  /// badge). Computed per request by the backend (`session_list.zig`
  /// via `git -C <cwd>`, same helper as the kanban task badge).
  git_branch?: string
  // Backend wall-clock timestamp of the last `sessions.UPDATE` — bumped by everything (agent loop,
  // profile change, error, etc).
  updated_at?: string
  /// Migration 063 — "0" / "1" opt-in for unattended mode. Always
  /// present in the GET /api/sessions response (ChatsList uses this
  /// to render the `🔁 unattended` badge).
  is_auto_retry_until_stop?: string
  // Migration 082 — unix-ms string of the last time a HUMAN interacted with this session. Empty
  // string (NOT undefined) for legacy rows so the ChatsList time pill can fall back to `updated_at`
  // predictably.
  last_human_touched_at?: string
  /// Migration 104 — pinned sessions (PINNED section above RECENT).
  /// True when the user pinned via right-click menu. Always present
  /// in GET /api/sessions (COALESCE'd server-side).
  is_pinned?: boolean
  /// Migration 104 — position inside the pinned region (MAX+1 on pin,
  /// 0 when unpinned). PINNED section sorts by this DESC.
  pinned_position?: number
  last_finish_reason?: string
  needs_human_review?: boolean
}

export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  created_at: number
  tool_name?: string
  tool_call_id?: string
  diffview_before?: string
  diffview_after?: string
  image_url?: string
  video_url?: string
  /** The attached files as a JSON array of `{name, mime, bytes}` — metadata only, never the bytes. */
  file_attachments?: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  tool_calls_json?: any
  finish_reason?: string
  is_input?: boolean
  is_output?: boolean
  /**    * 2026-08-23 hidden-messages fix — thinking models' chain-of-thought. Already returned by the
   * backend REST endpoint (http_response.zig SessionMessage.reasoning_content) and the SSE payload;
   * previously unmapped so ChatView never saw it. */
  reasoning_content?: string
}

export interface SkillInfo {
  skill_name: string
  content: string
  loaded_at?: number
}

// All chat endpoints go through Zig backend at /api/llm/*
// Zig backend internally calls LLM backend
// Parse timestamp - backend sends nanoseconds as string, convert to seconds
function parseTimestamp(ts: number | string): number {
  const num = typeof ts === 'string' ? parseInt(ts, 10) : ts
  // If timestamp looks like nanoseconds (> 1e12), convert to seconds
  return num > 1e12 ? Math.floor(num / 1e9) : num
}
/** The transcript fetch failed — transport, non-2xx, or an abort. Deliberately coarse: the UI acts
 * on "the transcript is unavailable", not on which kind of unavailable it is, and the retry policy
 * is the same for all three. */
export class ChatHistoryError extends Data.TaggedError('ChatHistoryError')<{
  readonly sessionId: string
  readonly reason: string
}> {}

/** An SSE frame that arrived on a named channel with a body that is not the JSON its wire name
 * promises. */
export class SseFrameError extends Data.TaggedError('SseFrameError')<{
  readonly eventType: string
  readonly reason: string
}> {}

/**  * What a best-effort transcript caller gets when the fetch failed. Named, not inlined, so the two
 * shapes can be diffed by eye: every field is `undefined` or empty because the answer genuinely is
 * unknown, and the only place this is legitimate is `getChatHistory`'s three metadata callers. */
const EMPTY_CHAT_HISTORY: ChatHistoryResponse = {
  messages: [],
  has_more: false,
  next_cursor: null,
  cwd: undefined,
  git_worktree_cwd: undefined,
  pr_url: undefined,
  pr_provider: undefined,
  // 2026-08-07-profile-persist-read — preserve the field shape on the error path so ChatView's
  // `loadChatHistory` branch can safely read `data.selected_profile_model` (it'll be `undefined`,
  // which ChatView coerces to `null`).
  selected_profile_model: undefined,
  max_total_tokens: undefined,
  max_capacity_total_tokens: undefined,
  total_count: undefined,
  skills: [],
}

export type ChatHistoryResponse = {
  messages: Message[]
  has_more: boolean
  next_cursor: string | null
  cwd?: string
  git_worktree_cwd?: string
  /// Attached PR URL (empty/missing = none). Mirrors sessions.pr_url.
  pr_url?: string
  /// Effective PR provider. Mirrors sessions.pr_provider.
  pr_provider?: string
  // Session's selected profile name (empty/missing = "Default", i.e. no profile selected). Mirrors
  // the backend `sessions.selected_profile_model` column.
  selected_profile_model?: string
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  total_count?: number
  skills?: SkillInfo[]
}

/** The transcript endpoint, WITH the failure in the type. Returns `Effect<ChatHistoryResponse,
 * ChatHistoryError>`, so "the backend is unreachable" is a value the caller must handle — it cannot
 * be mistaken for an empty transcript. */
export function fetchChatHistoryEffect(
  sessionId: string,
  limit = 50,
  cursor?: string,
  direction: 'asc' | 'desc' = 'desc',
  timeoutMs?: number,
): Effect.Effect<ChatHistoryResponse, ChatHistoryError> {
  const params = new URLSearchParams({
    sort_by: 'created_at',
    direction,
    limit: limit.toString(),
  })
  if (cursor) {
    params.set('cursor', cursor)
  }
  // silent: true — the failure is the caller's to handle (the chatview's retry loop + inline error UI
  // for the transcript; a console.log for the metadata callers), so a toast on 404/5xx would be noise.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  const toResponse = (data: any): ChatHistoryResponse => ({
    messages: data.messages.map(
      (msg: {
        id: string
        role: string
        content: string
        created_at: number | string
        tool_name?: string
        diffview_before?: string
        diffview_after?: string
        image_url?: string
        // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
        tool_calls_json?: any
        reasoning_content?: string
      }) => ({
        ...msg,
        content: msg.content,
        created_at: parseTimestamp(msg.created_at),
        tool_name: msg.tool_name,
        diffview_before: msg.diffview_before,
        diffview_after: msg.diffview_after,
        image_url: msg.image_url,
        tool_calls_json: msg.tool_calls_json,
        // 2026-08-23 hidden-messages fix — pass the thinking model's
        // reasoning through to ChatView (backend already returns it).
        reasoning_content: msg.reasoning_content || undefined,
      }),
    ),
    has_more: data.has_more,
    next_cursor: data.next_cursor,
    cwd: data.cwd,
    git_worktree_cwd: data.git_worktree_cwd,
    pr_url: data.pr_url,
    pr_provider: data.pr_provider,
    // 2026-08-07-profile-persist-read — read the per-session selected profile name so the chatview
    // chip can show the persisted selection on page refresh.
    selected_profile_model: data.selected_profile_model,
    max_total_tokens: data.max_total_tokens,
    max_capacity_total_tokens: data.max_capacity_total_tokens,
    total_count: data.total_count,
    skills: data.skills,
  })

  return Effect.tryPromise({
    try: () =>
      // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; matches `toResponse` above, which re-narrows each field.
      apiFetch<any>(`/llm/session/${encodeURIComponent(sessionId)}/messages?${params}`, {
        silent: true,
        ...(timeoutMs === undefined ? {} : { timeoutMs }),
      }),
    catch: (cause) => new ChatHistoryError({ sessionId, reason: describeCause(Cause.fail(cause)) }),
  }).pipe(Effect.map(toResponse))
}

/** Best-effort transcript: a failure yields an EMPTY transcript rather than a rejection,
 * implemented on the Effect seam so no `try`/`catch` sits between the failure and the value the
 * caller gets. */
export function getChatHistory(
  sessionId: string,
  limit = 50,
  cursor?: string,
  direction: 'asc' | 'desc' = 'desc',
): Promise<ChatHistoryResponse> {
  return Effect.runPromise(
    fetchChatHistoryEffect(sessionId, limit, cursor, direction).pipe(
      Effect.catchAll((error) => {
        // The reason is logged, not discarded — the AGENTS.md rule about
        // never letting a caught error vanish into an indistinguishable value.
        console.log(error)
        return Effect.succeed(EMPTY_CHAT_HISTORY)
      }),
    ),
  )
}

// Legacy chat functions (kept for compatibility)
export interface ChatLegacy {
  id: string
  label: string
  icon: string
  active?: boolean
}

export async function getChatsLegacy(): Promise<{ chats: ChatLegacy[] }> {
  return await apiFetch<{ chats: ChatLegacy[] }>('/chats')
}

export async function createChat(name: string, icon: string = '💬'): Promise<ChatLegacy> {
  return await apiFetch<ChatLegacy>('/chats', {
    method: 'POST',
    body: { name, icon },
  })
}

export async function deleteChat(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/chats/${id}`, { method: 'DELETE' })
}

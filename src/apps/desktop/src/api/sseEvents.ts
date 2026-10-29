import type { SkillInfo } from './chatHistory'
import type { DesignElementEvent } from './designElements'

// SSE event types matching the backend
// Note: Backend sends events without explicit 'type' field in data.
// The 'finish_reason' field indicates message completion.
export interface SseEvent {
  session_id: string
  id?: string
  content?: string
  role?: string
  finish_reason?: string
  reasoning_content?: string
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  tool_calls?: any
  // 2026-08-24 (task_1787545088500_6, bug A) — backend SseEventLLMHistory
  // (sse_on_event_send_llm_history.zig:150) sends the assistant row's serialized tool_calls array
  // on the wire as `tool_calls_json`.
  tool_calls_json?: string
  tool_call_id?: string
  tool_name?: string
  agent_name?: string
  loop_index?: number
  temperature?: number
  is_thinking?: boolean
  is_input?: boolean
  is_output?: boolean
  parent_session_id?: string
  parent_id?: string
  // 2026-09-04 subagent-peek fix: progress events (role="subagent_progress")
  // carry the child sid + lifecycle status on the same SseEvent wire.
  // Optional so existing llm_chunk/llm_full payloads are unaffected.
  subagent_session_id?: string
  status?: string
  created_at?: number
  // Legacy type field for compatibility (not used by backend)
  type?: 'chunk' | 'reasoning_chunk' | 'chunk_final' | 'tool_call_delta' | 'connected' | 'full'
  index?: number
  total_tokens?: number
  // Diff view data for text_replace tool
  diffview_before?: string
  diffview_after?: string
  // Pipe-separated image URLs (matches the REST SessionMessageResponse shape and the backend
  // onEventSendLLMHistory payload). Frontend splits on '|' to populate Message.image_urls.
  image_url?: string
  // Pipe-separated video URLs (Migration 090, backend
  // SseEventLLMHistory.video_url). Split on '|' into video_urls.
  video_url?: string
  // The attached files as a JSON array of `{name, mime, bytes}` — metadata only.
  file_attachments?: string
  // Live session skills pushed on the SSE wire (backend: sse_on_event_send_llm_history.zig:45
  // SseEventLLMHistory.session_skills, next to is_error).
  session_skills?: SkillInfo[]
  // True when this event is an agentic-loop diagnostic (retry attempt or TooManyRetries bail)
  // rather than a real chat turn. Backend: sse_on_event_send_llm_history.zig
  // SseEventLLMHistory.is_error — set by workflow.zig's 3 diagnostic sites.
  is_error?: boolean
}

// Session event types for SSE subscription
export interface SessionEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  name: string
  status: string
  cwd: string
  created_at: string
  updated_at: string
  selected_profile_model?: string
  // Mirrors `git_worktree_cwd` on the Session interface: empty
  // string when no worktree is bound, omitted for events that don't
  // carry session fields (e.g. delete).
  git_worktree_cwd?: string
  // Mirrors sessions.is_auto_retry_until_stop (Migration 063). Only present on 'updated' events
  // where the session row carries the flag.
  is_auto_retry_until_stop?: string
  // Migration 082 — the touched POST's SSE echo carries the fresh stamp (unix-ms integer string,
  // raw column shape — NOT the SQLite datetime the REST list returns). Optional: older backends
  // omit it. ChatsList uses it only for echo detection, never for display.
  last_human_touched_at?: string
}

// Queue messages SSE event types
export type QueueMessageEvent =
  | {
      action: 'queued'
      id: string
      message: string
      image_url?: string
      video_url?: string
      session_id: string
    }
  | {
      action: 'deleted'
      id: string
      session_id: string
    }

// Background-process lifecycle SSE event (see src/agentic_loop/background_process_events.zig). Both
// granular wire names (`background_process_created` / `background_process_completed`) share this
// payload; the consumer filters by `session_id` and re-fetches the list.
export interface BackgroundProcessEvent {
  action: 'created' | 'completed'
  session_id: string
  pid: number
  command: string
}

// Skill-eval lifecycle SSE event (see src/agentic_loop/skill_eval_events.zig). All three granular
// wire names (`skill_evals_run_started` / `_run_finished` / `_result_applied`) share this payload;
// the consumer filters by `session_id` and re-fetches the eval list for the Evals tab.
export interface SkillEvalEvent {
  action: 'run_started' | 'run_finished' | 'result_applied'
  run_id: string
  session_id: string
  evaluated: number
  result_id: string
}

// File stage/unstage SSE event (see src/agentic_loop/git_file_stage_events.zig).
export interface GitFileStageEvent {
  action: 'staged' | 'unstaged'
  /** Repo-relative path that moved. */
  path: string
  /** The worktree the git command ran in. */
  cwd: string
  /** True when git failed for this path — the row must NOT move. */
  failed: boolean
}

// Change-request state SSE event (see src/agentic_loop/git_pr_state_events.zig).
export interface GitPrStateEvent {
  action: 'merged' | 'closed'
  /** The worktree the forge command ran in. */
  cwd: string
  /** The change request's head branch (`head_ref`). */
  branch: string
}

// ─── Skill Evals read surface (GET /api/skill-evals/*) ──────────────────
export interface SkillEvalRun {
  id: string
  session_id: string
  status: string
  trigger: string
  scope: string
  skill_name: string
  error: string
  total_tokens: number
  created_at: string
}

export interface SkillEvalResult {
  id: string
  skill_name: string
  skill_key: string
  status: string
  verdict: string
  freshness: number
  accuracy: number
  duplication: number
  rationale: string
  /** A JSON *string* (the stored array) — parse it before use. */
  missing_paths: string
  /** Whether the intrinsic half came from the shared fact cache. */
  shared_fact: boolean
  applied: boolean
  apply_action: string
}

export interface SkillEvalsRunsResponse {
  runs: SkillEvalRun[]
  results: SkillEvalResult[]
}

export interface SkillEvalsSummaryResponse {
  counts: { verdict: string; n: number }[]
  total: number
}

// Workers SSE event types
export interface WorkerEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  session_id: string
  working_directory: string
  last_activity: number
  last_activity_description: string
  created_at: string
}

// Kanban SSE event types
// (see src/ai_workflow/tui/on_event_sent_kanban.zig on the backend).
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_description?: string | null
  new_position?: number | null
}

export interface KanbanTaskEvent {
  // Backend's full action enum (on_event_sent_kanban.zig KanbanTaskAction). Added in the
  // sse-kanban-move-duplicate-task plan (2026-08-06).
  action: 'assigned' | 'moved' | 'unassigned' | 'human_touched'
  workspace_id: string
  item_id: string
  task_id: string
  new_column_id?: string | null
  new_position?: number | null
  // After-action review state — present ONLY on `human_touched` events (task_mark_human_touched.zig
  // sends `false`; null on assigned/moved/unassigned).
  needs_human_review?: boolean | null
}

export interface DocumentEvent {
  // Backend's action enum (src/agentic_loop/document_events.zig).
  action: 'created' | 'updated' | 'deleted'
  workspace_id: string
  document_id: string
  // The title AFTER the mutation; `''` when the mutation did not read the row back.
  title: string
}

/** Unified SSE channel options. Each property is a per-channel callback. Only the keys present in
 * `channels` are subscribed on the backend (passed as the `?channels=` query param). */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  /** Subscribe to background-process lifecycle events. The backend emits two granular names
   * (`background_process_created` on spawn, `background_process_completed` on exit) that share the
   * same `BackgroundProcessEvent` payload. */
  backgroundProcess?: (event: BackgroundProcessEvent) => void
  /** Subscribe to skill-eval lifecycle events. The backend emits three granular names
   * (`skill_evals_run_started`, `skill_evals_run_finished`, `skill_evals_result_applied`) that
   * share the same `SkillEvalEvent` payload. */
  skillEvals?: (event: SkillEvalEvent) => void
  /** Subscribe to file stage/unstage events. The backend emits two granular names
   * (`git_file_staged` on `git add`, `git_file_unstaged` on `git restore --staged`) that share the
   * same `GitFileStageEvent` payload. */
  gitFileStage?: (event: GitFileStageEvent) => void
  /** Subscribe to change-request state events. */
  gitPrState?: (event: GitPrStateEvent) => void
  /** Subscribe to document mutations. The backend emits three granular names (`document_created`,
   * `document_updated`, `document_deleted`) sharing one `DocumentEvent` payload. Only an agent tool
   * emits these, so a tab never receives an echo of its own UI edit. */
  documents?: (event: DocumentEvent) => void
  /** Subscribe to design-mode element mutations. The backend emits three granular event names
   * (`design_element_created`, `design_element_updated`, `design_element_deleted`) that share the
   * same `DesignElementEvent` payload (the `action` discriminator tells them apart). */
  design?: (event: DesignElementEvent) => void
  /** Subscribe to LLM streaming events. When `sessionId` is provided, the factory sends `llm:<sid>`
   * (per-session routing — used by any future caller that wants server-side filtering). */
  llm?: { sessionId?: string; onEvent: (event: SseEvent) => void }
  /**    * Subscribe to queue-message events. Same pattern as `llm`: `sessionId` provided → per-session
   * routing; omitted → central key (consumer filters by `event.session_id`). */
  queue?: { sessionId?: string; onEvent: (event: QueueMessageEvent) => void }
}

export interface UnifiedSseOptions {
  channels: UnifiedChannels
  onError?: (error: Event) => void
  onConnected?: () => void
}

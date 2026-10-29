import { createSseClient, type SseClient } from '../helpers/sseClient'
import { Cause, Effect, Exit, Option } from 'effect'
import { describeCause } from '../helpers/effectRuntime'
import { SseFrameError } from './chatHistory'
import { API_BASE } from './core'
import type { DesignElementEvent } from './designElements'
import type {
  SseEvent,
  SessionEvent,
  QueueMessageEvent,
  BackgroundProcessEvent,
  SkillEvalEvent,
  GitFileStageEvent,
  GitPrStateEvent,
  WorkerEvent,
  KanbanColumnEvent,
  KanbanTaskEvent,
  DocumentEvent,
  UnifiedSseOptions,
} from './sseEvents'

/** Open ONE EventSource that fans out every event family the caller wired up. */
export function createUnifiedSseConnection(opts: UnifiedSseOptions): SseClient {
  // 1. Build the ?channels= comma-separated list.
  const tokens: string[] = []
  if (opts.channels.workers) tokens.push('workers')
  if (opts.channels.sessions) tokens.push('sessions')
  if (opts.channels.kanban) tokens.push('kanban')
  if (opts.channels.design) tokens.push('design_element')
  if (opts.channels.llm) {
    tokens.push(opts.channels.llm.sessionId ? `llm:${opts.channels.llm.sessionId}` : 'llm')
  }
  if (opts.channels.queue) {
    tokens.push(opts.channels.queue.sessionId ? `queue:${opts.channels.queue.sessionId}` : 'queue')
  }
  if (opts.channels.backgroundProcess) tokens.push('background_process')
  if (opts.channels.skillEvals) tokens.push('skill_evals')
  if (opts.channels.gitFileStage) tokens.push('git_file_stage')
  if (opts.channels.gitPrState) tokens.push('git_pr_state')
  if (opts.channels.documents) tokens.push('documents')

  // Empty subscriptions are meaningless; the backend would 400 anyway. Throw early with a
  // developer-friendly message.
  if (tokens.length === 0) {
    console.error(
      '[unifiedSSE] createUnifiedSseConnection: opts.channels is empty — no EventSource will be created',
      opts.channels,
    )
    throw new Error('createUnifiedSseConnection: opts.channels is empty')
  }

  // Per-channel JSON buffer for the unnamed default `message` event, if any are emitted.
  const defaultMessageBuf = { value: '' }

  return createSseClient({
    url: `${API_BASE}/events?channels=${tokens.join(',')}`,
    onConnected: opts.onConnected,
    // Every named event type the backend can emit MUST be pre-registered — the browser's
    // EventSource only dispatches each `event: <name>` to listeners registered for that exact name.
    // See the SseClient JSDoc + the project memory browser-eventsource-named-events.md.
    additionalEventTypes: [
      'kanban_column',
      'kanban_task',
      'queue_queued',
      'queue_deleted',
      'llm_chunk',
      'llm_full',
      'worker_created',
      'worker_updated',
      'worker_deleted',
      // Throw-isolation / forward-compat: the backend emits these fallback/granular names (see
      // on_event_sent.zig + on_event_sent_design.zig).
      'worker_unknown',
      'session_created',
      'session_deleted',
      'session_updated', // task_1786507100896 — auto-rename on first user message + unattended toggle
      'session_unknown',
      // Design-mode element events (see src/ai_workflow/tui/on_event_sent_design.zig). All granular
      // single-element events share the `DesignElementEvent` payload; the `action` discriminator
      // tells them apart.
      'design_element_created',
      'design_element_updated',
      'design_element_deleted',
      'design_elements_geometry_batch_updated',
      // Backend also emits `design_page_deleted` (routing key `design_page`) and `close`
      // (server-shutdown frame).
      'design_page_deleted',
      'close',
      // Background-process lifecycle (see background_process_events.zig).
      // Without pre-registration the browser drops the event before
      // onEvent ever fires — the list would never refresh.
      'background_process_created',
      'background_process_completed',
      // Auth rejection (`event: auth_error`, see unified_events_sse.zig `terminateSseStream`).
      // Without pre-registration the browser drops it before onEvent ever fires and the client sits
      // in 'connecting' until the stream closes — indistinguishable from a dead backend.
      'auth_error',
      // Skill-eval lifecycle (see src/agentic_loop/skill_eval_events.zig). Three granular names
      // share one payload; all route on the central `skill_evals` key.
      'skill_evals_run_started',
      'skill_evals_run_finished',
      'skill_evals_result_applied',
      // File stage/unstage (see src/agentic_loop/git_file_stage_events.zig). Two granular names
      // share one payload; both route on the central `git_file_stage` key.
      'git_file_staged',
      'git_file_unstaged',
      // Change-request state (see src/agentic_loop/git_pr_state_events.zig). Two granular names
      // share one payload; both route on the central `git_pr_state` key.
      'git_pr_state_merged',
      'git_pr_state_closed',
      // Document mutations (see src/agentic_loop/document_events.zig). Three granular names share
      // one payload; all route on the central `documents` key.
      'document_created',
      'document_updated',
      'document_deleted',
    ],
    // Default heartbeat filter (matches backend sse_manager.sendHeartbeat).
    heartbeatData: 'ping',
    onEvent: (raw: string, eventType: string) => {
      if (eventType === 'connected') {
        // Reset the buffer on (re)connect — leftover bytes from the
        // previous connection would corrupt the next parse.
        defaultMessageBuf.value = ''
        return
      }

      // Named events: dispatch by eventType.
      if (eventType === 'kanban_column' || eventType === 'kanban_task') {
        if (!opts.channels.kanban) return
        try {
          const data = JSON.parse(raw)
          opts.channels.kanban(data as KanbanColumnEvent | KanbanTaskEvent)
        } catch (err) {
          console.error('[unifiedSSE] kanban event parse failed:', err, raw)
        }
        return
      }

      // Design-mode element events.
      if (
        eventType === 'design_element_created' ||
        eventType === 'design_element_updated' ||
        eventType === 'design_element_deleted' ||
        eventType === 'design_elements_geometry_batch_updated'
      ) {
        if (!opts.channels.design) return
        try {
          const data = JSON.parse(raw)
          opts.channels.design(data as DesignElementEvent)
        } catch (err) {
          console.error('[unifiedSSE] design event parse failed:', err, raw)
        }
        return
      }

      if (eventType === 'queue_queued' || eventType === 'queue_deleted') {
        if (!opts.channels.queue) return
        try {
          const data = JSON.parse(raw)
          opts.channels.queue.onEvent(data as QueueMessageEvent)
        } catch (err) {
          console.error('[unifiedSSE] queue event parse failed:', err, raw)
        }
        return
      }

      // Document mutations (agent tools only — `add_document` / `edit_document` /
      // `delete_document`). All three granular names share one `DocumentEvent` payload.
      if (
        eventType === 'document_created' ||
        eventType === 'document_updated' ||
        eventType === 'document_deleted'
      ) {
        if (!opts.channels.documents) return
        const frame = Effect.runSyncExit(
          Effect.try({
            try: () => JSON.parse(raw) as DocumentEvent,
            catch: (cause) =>
              new SseFrameError({ eventType, reason: describeCause(Cause.fail(cause)) }),
          }),
        )
        if (Exit.isSuccess(frame)) {
          opts.channels.documents(frame.value)
        } else {
          const failed = Option.getOrUndefined(Cause.failureOption(frame.cause))
          console.error(
            `[unifiedSSE] ${eventType} event parse failed:`,
            failed instanceof SseFrameError ? failed.reason : describeCause(frame.cause),
            raw,
          )
        }
        return
      }

      // Background-process lifecycle. Both granular names share the
      // `BackgroundProcessEvent` payload — the consumer filters by
      // `session_id` and re-fetches the list.
      if (
        eventType === 'background_process_created' ||
        eventType === 'background_process_completed'
      ) {
        if (!opts.channels.backgroundProcess) return
        try {
          const data = JSON.parse(raw)
          opts.channels.backgroundProcess(data as BackgroundProcessEvent)
        } catch (err) {
          console.error('[unifiedSSE] background_process event parse failed:', err, raw)
        }
        return
      }

      // Skill-eval lifecycle. All three granular names share the
      // `SkillEvalEvent` payload — the consumer filters by `session_id`
      // and re-fetches the eval list for the Evals tab.
      if (
        eventType === 'skill_evals_run_started' ||
        eventType === 'skill_evals_run_finished' ||
        eventType === 'skill_evals_result_applied'
      ) {
        if (!opts.channels.skillEvals) return
        try {
          const data = JSON.parse(raw)
          opts.channels.skillEvals(data as SkillEvalEvent)
        } catch (err) {
          console.error('[unifiedSSE] skill_evals event parse failed:', err, raw)
        }
        return
      }

      // LLM streaming chunks / full responses. The backend sets `event_type = "llm_chunk"` for
      // content/reasoning/tool-call/final chunks (per `on_event_sent.zig` `sendStreamChunk*`) and
      // `event_type = "llm_full"` for non-streaming full responses (`onEventSendLLMHistory`).
      if (eventType === 'llm_chunk' || eventType === 'llm_full') {
        if (!opts.channels.llm) return
        try {
          const data = JSON.parse(raw)
          opts.channels.llm.onEvent(data as SseEvent)
        } catch (err) {
          console.error('[unifiedSSE] llm event parse failed:', err, raw)
        }
        return
      }

      // Worker events. The backend sets `worker_created` | `worker_updated` | `worker_deleted`
      // based on `OnEventInputWorkers.action` (see `on_event_sent.zig`), plus `worker_unknown` as a
      // future-proofing fallback for new actions.
      if (
        eventType === 'worker_created' ||
        eventType === 'worker_updated' ||
        eventType === 'worker_deleted' ||
        eventType === 'worker_unknown'
      ) {
        if (!opts.channels.workers) return
        try {
          const data = JSON.parse(raw)
          opts.channels.workers(data as WorkerEvent)
        } catch (err) {
          console.error('[unifiedSSE] worker event parse failed:', err, raw)
        }
        return
      }

      // Session events.
      if (
        eventType === 'session_created' ||
        eventType === 'session_updated' ||
        eventType === 'session_deleted' ||
        eventType === 'session_unknown'
      ) {
        if (!opts.channels.sessions) return
        try {
          const data = JSON.parse(raw)
          opts.channels.sessions(data as SessionEvent)
        } catch (err) {
          console.error('[unifiedSSE] session event parse failed:', err, raw)
        }
        return
      }

      // File stage/unstage. Both granular names share the `GitFileStageEvent` payload — the
      // consumer filters by `cwd` and moves ONE row between Staged / Changes / Untracked instead of
      // re-fetching the whole git-status list.
      if (eventType === 'git_file_staged' || eventType === 'git_file_unstaged') {
        if (!opts.channels.gitFileStage) return
        try {
          const data = JSON.parse(raw)
          opts.channels.gitFileStage(data as GitFileStageEvent)
        } catch (err) {
          console.error('[unifiedSSE] git_file_stage event parse failed:', err, raw)
        }
        return
      }

      // Change-request state (merged / closed).
      if (eventType === 'git_pr_state_merged' || eventType === 'git_pr_state_closed') {
        if (!opts.channels.gitPrState) return
        const frame = Effect.runSyncExit(
          Effect.try({
            try: () => JSON.parse(raw) as GitPrStateEvent,
            catch: (cause) =>
              new SseFrameError({ eventType, reason: describeCause(Cause.fail(cause)) }),
          }),
        )
        if (Exit.isSuccess(frame)) {
          opts.channels.gitPrState(frame.value)
        } else {
          const failed = Option.getOrUndefined(Cause.failureOption(frame.cause))
          console.error(
            `[unifiedSSE] ${eventType} event parse failed:`,
            failed instanceof SseFrameError ? failed.reason : describeCause(frame.cause),
            raw,
          )
        }
        return
      }

      // Server-shutdown frame (`event: close`, see sse_manager.zig). Explicitly ignored — the
      // browser fires `error` + the client reconnects via its own backoff.
      if (eventType === 'close') {
        return
      }

      // Auth rejection (`event: auth_error`, see unified_events_sse.zig `terminateSseStream`).
      if (eventType === 'auth_error') {
        try {
          const loc = globalThis.location
          if (loc && !loc.pathname.startsWith('/login')) {
            loc.href = `/login?redirect=${encodeURIComponent(loc.pathname + loc.search)}`
          }
        } catch {
          /* non-browser (vitest) — no redirect */
        }
        return
      }

      // `design_page_deleted` shares the design channel (page-level delete; the consumer
      // re-fetches). Registered so the browser doesn't drop it silently; forwarded best-effort like
      // the element events above.
      if (eventType === 'design_page_deleted') {
        if (!opts.channels.design) return
        try {
          const data = JSON.parse(raw)
          opts.channels.design(data as DesignElementEvent)
        } catch (err) {
          console.error('[unifiedSSE] design page event parse failed:', err, raw)
        }
        return
      }

      // Default `message` events: 3 distinct JSON shapes, differentiated by which consumer
      // registered the channel.
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        defaultMessageBuf.value += trimmed + '\n'
        const jsonStart = defaultMessageBuf.value.indexOf('{')
        const jsonEnd = defaultMessageBuf.value.lastIndexOf('}')
        if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
          // Incomplete JSON object — wait for more bytes. If the buffer grows unbounded (e.g.
          // server sends invalid JSON), a future fix could add a size guard; current callers trust
          // the backend's wire format.
          return
        }
        const jsonStr = defaultMessageBuf.value.slice(jsonStart, jsonEnd + 1)
        let parsed: unknown
        try {
          parsed = JSON.parse(jsonStr)
        } catch {
          // Invalid JSON; drop the leading bytes and keep accumulating. (Defensive — the backend's
          // std.json.fmt should always emit valid JSON. But a buggy future emitter shouldn't crash
          // the SSE.)
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonStart + 1)
          return
        }

        const obj = parsed as Record<string, unknown>
        // Order matters: check session BEFORE worker because both have `action`; the discriminator
        // is `working_directory` (worker has it, session doesn't) plus `status` (session has it,
        // worker doesn't). Either combination uniquely identifies.
        try {
          if (
            opts.channels.sessions &&
            typeof obj.action === 'string' &&
            typeof obj.status === 'string' &&
            typeof obj.cwd === 'string'
          ) {
            try {
              opts.channels.sessions(obj as unknown as SessionEvent)
            } catch (err) {
              console.error('[unifiedSSE] session channel subscriber threw:', err)
            }
          } else if (
            opts.channels.workers &&
            typeof obj.action === 'string' &&
            typeof obj.working_directory === 'string'
          ) {
            try {
              opts.channels.workers(obj as unknown as WorkerEvent)
            } catch (err) {
              console.error('[unifiedSSE] worker channel subscriber threw:', err)
            }
          } else if (opts.channels.llm && (obj.type === 'chunk' || obj.type === 'full')) {
            try {
              opts.channels.llm.onEvent(obj as unknown as SseEvent)
            } catch (err) {
              console.error('[unifiedSSE] llm channel subscriber threw:', err)
            }
          }
        } finally {
          // ALWAYS advance past the consumed JSON object, regardless of whether a consumer matched
          // or threw.
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonEnd + 1)
        }
      } catch (e) {
        console.error('[unifiedSSE] default message dispatch error:', e)
      }
    },
    onStateChange: (state, info) => {
      // Match the convention of the 5 old factories: terminal-failure only. Transient errors are
      // retried internally by the SseClient. See memory pabrik-sse-incomplete-chunked-encoding.md
      // for why ChatView's isStreaming flag flips ONLY on 'failed'.
      if (state === 'failed') {
        try {
          opts.onError?.(info.lastError ?? new Event('error'))
        } catch (err) {
          console.error('[unifiedSSE] onError subscriber threw:', err)
        }
      }
    },
  })
}

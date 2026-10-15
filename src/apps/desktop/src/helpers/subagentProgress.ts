/**
 * subagentProgress.ts — pure helper for the chatview's spawn_sub_agent
 * live-progress feature.
 *
 * 2026-08-23 spawn-subagent-live-progress: the chatview's
 * SpawnSubAgent.vue card has been rendering "0 sub-agents" until the
 * parent's tool result row was populated (which only happens after
 * `group.await()` joins every sub-agent thread). This module feeds a
 * per-tool_call_id progress map that lives in ChatView.vue, so the
 * card flips from "0 sub-agents" to live per-agent rows in real
 * time.
 *
 * The reducer is pure: it takes the current map (keyed by parent
 * tool_call_id) and a single `SubAgentProgressEvent`, and returns a
 * NEW map with that event applied. Vue's reactivity requires
 * map-by-replacement (not in-place mutation) for rows to re-render,
 * so we always clone before writing.
 *
 * Wire format: the backend's `subagent_progress.zig` emitter produces
 * a `SseEvent` with `role = "subagent_progress"`. The payload
 * carries:
 *   - parent `session_id` (the chatview filters on this already)
 *   - parent `tool_call_id` (key for the per-batch progress map)
 *   - `agent_name`, `status`, `agent_index`, `total_agents`
 *   - `subagent_session_id` (only present when the sub-agent has
 *     allocated its session — frontend reducer stores undefined when
 *     absent so the peek button stays disabled)
 *   - `elapsed_ms` (drives the "running for 12s" chip)
 *
 * Adding a wire field: extend `SubAgentProgressEvent` here AND the
 * `SubAgentProgress` type below. Adding a NEW status value (e.g.
 * "cancelled"): add to `ProgressStatus` enum here AND the enum in
 * `subagent_progress.zig` (the values must stay in sync).
 */

/** Wire-level enum mirrored from subagent_progress.zig `ProgressStatus`. */
export type ProgressStatus = 'launched' | 'completed' | 'failed'

/** Sub-agent lifecycle status as exposed to UI rendering. */
export type SubAgentRowStatus = 'running' | 'done' | 'failed'

/** Wire shape of one `role="subagent_progress"` SSE event, as parsed
 * from `JSON.parse(raw)` in the SSE bus handler. All fields except
 * `status`/`agent_index`/`total_agents` are optional because the
 * `launched` event arrives first (with no response) and later events
 * add the completion details. */
export interface SubAgentProgressEvent {
  /** MUST be `'subagent_progress'`. The bus handler uses this to
   * route into `applyProgressEvent` instead of the regular
   * message-list path. */
  role?: 'subagent_progress'
  /** Parent session id — the chatview bus already filters on this. */
  session_id?: string
  /** Parent tool_call id — the reducer keys the per-batch map by it. */
  tool_call_id?: string
  /** LLM-provided sub-agent name (the row title). */
  agent_name?: string
  status?: ProgressStatus
  /** 0-based position within the spawn batch. Stable across events
   * for the same agent. */
  agent_index?: number
  /** Total sub-agents in this spawn batch. Same for every event in
   * the batch — used for "1 of 3" chips. */
  total_agents?: number
  /** Sub-agent's own session_id, allocated in runSubAgent AFTER
   * thread entry. Absent (undefined) on `launched` events for a few
   * ms until the alloc finishes; present on `completed`/`failed`
   * unless the failure happened before allocation. */
  subagent_session_id?: string
  /** Wall-clock ms since the sub-agent thread entered runSubAgent. */
  elapsed_ms?: number
}

/** UI-facing shape of one progress row, consumed by SpawnSubAgent.vue. */
export interface SubAgentProgress {
  /** Display name (defaults to `agent_<index>` if missing). */
  name: string
  status: SubAgentRowStatus
  index: number
  total: number
  /** Sub-agent session id (undefined → peek button stays disabled). */
  sessionId?: string
  /** Wall-clock ms since the sub-agent thread entered. */
  elapsedMs: number
}

/** Per-batch map keyed by parent tool_call_id. */
export type SubAgentProgressMap = Record<string, SubAgentProgress[]>

/**
 * True when a tool message is a spawn_sub_agent row still in Phase 1
 * placeholder state (no `<summary>` → the tool hasn't completed).
 * Used by ChatView.rehydrateSubAgentProgress to decide which rows
 * need a snapshot fetch. Mirrors SpawnSubAgent.vue's `isStarting`
 * (agents==0 && summary==null && no live rows) at the message-list
 * level: the final envelope in `tools_exec_spawn_sub_agent.zig`
 * always prints `<summary succeeded= failed= />`, so its absence
 * means the batch is still running.
 */
export function isPlaceholderSpawnRow(msg: {
  role?: string
  tool_name?: string | null
  tool_call_id?: string | null
  content?: string | null
}): boolean {
  return (
    msg.role === 'tool' &&
    msg.tool_name === 'spawn_sub_agent' &&
    !!msg.tool_call_id &&
    typeof msg.content === 'string' &&
    !msg.content.includes('<summary') &&
    // A pre-thread failure envelope (<success>false</success>, no <summary>) means the tool HAS
    // completed — it is not a placeholder, so rehydrate must not poll the snapshot for it and the
    // card must not render "starting…".
    !msg.content.includes('<success>false</success>')
  )
}

/**
 * Pure reducer: apply ONE progress event to the current map and
 * return a NEW map. Vue reactivity demands map-by-replacement; we
 * never mutate the input.
 *
 * Defensive: ignores events that don't carry the required fields
 * (no role / tool_call_id / status / agent_index). Such events
 * would indicate a backend regression — return the original map
 * so the UI keeps its previous state.
 */
export function applyProgressEvent(
  map: SubAgentProgressMap,
  event: SubAgentProgressEvent,
): SubAgentProgressMap {
  if (event.role !== 'subagent_progress') return map
  const toolCallId = event.tool_call_id
  if (!toolCallId) return map
  const status = event.status
  if (!status) return map
  const index = typeof event.agent_index === 'number' ? event.agent_index : -1
  if (index < 0) return map

  const existing = map[toolCallId] ?? []
  // Find or create the row at this index.
  const next: SubAgentProgress[] = existing.slice()
  while (next.length <= index) {
    next.push({
      name: `agent_${next.length}`,
      status: 'running',
      index: next.length,
      total: event.total_agents ?? next.length + 1,
      elapsedMs: 0,
    })
  }
  // The while-loop above guarantees next[index] exists at this point.
  const prev: SubAgentProgress = next[index] ?? {
    name: `agent_${index}`,
    status: 'running',
    index,
    total: event.total_agents ?? 1,
    elapsedMs: 0,
  }
  const statusForUi: SubAgentRowStatus =
    status === 'completed' ? 'done' : status === 'failed' ? 'failed' : 'running'

  // Don't regress: a `launched` event arriving AFTER `completed`
  // (out-of-order delivery on a real network is rare but possible)
  // must NOT downgrade a done row back to running. Only `failed`
  // can override `done` (a sub-agent that succeeded but then had its
  // result truncated is a real edge case worth showing).
  let finalStatus: SubAgentRowStatus = statusForUi
  if (prev.status === 'done' && statusForUi === 'running') {
    finalStatus = 'done'
  }

  next[index] = {
    name: event.agent_name ?? prev.name,
    status: finalStatus,
    index,
    total: event.total_agents ?? prev.total,
    // Persist sessionId once it appears; do NOT clear it back to
    // undefined on later events (it's stable for the lifetime of
    // the sub-agent's session).
    sessionId: event.subagent_session_id ?? prev.sessionId,
    elapsedMs: typeof event.elapsed_ms === 'number' ? event.elapsed_ms : prev.elapsedMs,
  }

  return { ...map, [toolCallId]: next }
}

/** Drop a batch's progress once the final <results> envelope arrives
 * (the parsed-results view takes over rendering). Returns a new map
 * with the entry removed. */
export function clearProgressFor(
  map: SubAgentProgressMap,
  toolCallId: string,
): SubAgentProgressMap {
  if (!(toolCallId in map)) return map
  const next: SubAgentProgressMap = { ...map }
  delete next[toolCallId]
  return next
}

/**
 * 2026-09-04 refresh rehydrate (task_1788505292766_1): fold a
 * `GET /api/subagent/progress` snapshot into the map. Each snapshot
 * row maps 1:1 onto a `SubAgentProgressEvent`, so we reuse the tested
 * `applyProgressEvent` reducer (including its done→running guard).
 * Backend "" session ids normalize to undefined — same as the
 * omitted wire field on the live SSE path (peek stays disabled).
 * Returns a NEW map (map-by-replacement for Vue reactivity); an
 * empty snapshot leaves the map untouched.
 */
export function applySnapshotRows(
  map: SubAgentProgressMap,
  toolCallId: string,
  rows: Array<{
    agent_name: string
    status: ProgressStatus
    agent_index: number
    total_agents: number
    subagent_session_id: string
    elapsed_ms: number
  }>,
): SubAgentProgressMap {
  let next = map
  for (const row of rows) {
    next = applyProgressEvent(next, {
      role: 'subagent_progress',
      tool_call_id: toolCallId,
      agent_name: row.agent_name,
      status: row.status,
      agent_index: row.agent_index,
      total_agents: row.total_agents,
      subagent_session_id: row.subagent_session_id || undefined,
      elapsed_ms: row.elapsed_ms,
    })
  }
  return next
}

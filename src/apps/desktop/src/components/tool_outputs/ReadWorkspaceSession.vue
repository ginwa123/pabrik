<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { extractParam } from '../../helpers/extractParam'
import { normalizeToolContent } from './_shared/toolOutputParser'

/**
 * ReadWorkspaceSession — renders the `read_workspace_session` tool result
 * (see `read_workspace_session.zig`). The tool is the LLM's window into
 * OTHER chat sessions in its own workspace — list, FTS search, per-session
 * read, and search-within — so surfacing it as a structured card matters:
 * a raw JSON dump in the chat is unreadable.
 *
 * The payload is JSON inside the standard tool envelope
 * (`{tool, parameters, success, data, error, v}`); this card renders
 * `data`, which is discriminated by `behavior`:
 *
 *   behavior="list" (workspace session discovery):
 *     { behavior, limit, count, total_count,
 *       sessions: [{ id, name, status, message_count, last_activity, preview }] }
 *
 *   behavior="search" | "search-within" (FTS results):
 *     { behavior, query, session_id, offset, limit, count, total_count,
 *       results: [{ id, session_id, session_name, role, created_at, snippet }],
 *       full_contents: [{ id, session_id, role, content, content_truncated }] | null }
 *
 *   behavior="read" (per-session message index):
 *     { behavior, order, session_id, count, total_count,
 *       message_index: [{ id, role, created_at, preview, tool_call_id,
 *                         tool_name, content, content_truncated }] }
 *
 *   denied: { denied: true, session_id, message }
 *   error:  { error: "..." }
 *
 * Two details worth knowing before editing this file:
 *
 *   * `snippet` marks its match with BARE brackets, not tags. The backend
 *     calls `snippet(messages_fts, 0, '[', ']', '...', 10)`, so a real value
 *     looks like `...a [portal] that refuses...`. `parseSnippet` also
 *     tolerates `[match]`/`[/match]` for transcripts persisted earlier.
 *
 *   * `created_at` is `YYYY-MM-DD HH:MM:SS` (the `created_iso` column), the
 *     same format the tool's own `since`/`until` parameters accept. It sorts
 *     lexicographically, which is what makes the recency grouping below
 *     correct. It was a raw nanosecond epoch until commit 1655f221.
 *
 * Search results are grouped by `session` and a role-facet footer shows
 * page-scoped counts — the backend indexes the whole JSON envelope for
 * tool rows, so a natural-language query matches tool output heavily and
 * the ratio is worth surfacing.
 */

// ── Shared types ──────────────────────────────────────────────────────────

interface WorkspaceSession {
  id: string
  name: string
  status: string
  message_count: number
  last_activity?: string
  preview: string
}

interface SearchEntry {
  id: string
  session_id: string
  session_name: string
  role: string
  created_at?: string
  /** Raw snippet with the FTS match wrapped in bare brackets — we render
   *  those as a highlighted span rather than raw text. */
  snippet: string
}

/** A run of search hits that share a `session_id`. */
interface SearchGroup {
  /** '' for hits that carry no session_id (single "no session" bucket). */
  key: string
  sessionId: string
  sessionName: string
  entries: SearchEntry[]
  newestAt?: string
}

/** A role count for the current page. */
interface RoleFacet {
  role: string
  count: number
}

/** One entry of the backend's `full_contents` array. */
interface FullContent {
  id: string
  role: string
  content: string
  content_truncated: boolean
}

interface ReadEntry {
  id: string
  role: string
  created_at?: string
  preview: string
  tool_call_id?: string
  tool_name?: string
  /**    * Present only when the caller passed `message_ids` and the LLM wants the full body. `truncated`
   * is true if the body was clipped to `MAX_FULL_CONTENT_BYTES` (16 KB) by the backend. */
  content?: string
  content_truncated?: boolean
}

const props = defineProps<{
  content: unknown
  expanded?: boolean
  parameters?: string
}>()

/** The card is presentation-only — it never routes. ChatView listens and
 * owns the navigation, same as `SpawnSubAgent`'s `peek` event. */
const emit = defineEmits<{ openSession: [sessionId: string] }>()

function openSession(sessionId: string): void {
  if (!sessionId) return
  emit('openSession', sessionId)
}

const isExpanded = ref(props.expanded ?? false)

function asRecord(v: unknown): Record<string, unknown> {
  if (typeof v === 'string') {
    try {
      const parsed: unknown = JSON.parse(v)
      return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
        ? (parsed as Record<string, unknown>)
        : {}
    } catch {
      return {}
    }
  }
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {}
}

function strOrNull(v: unknown): string | null {
  if (v === null || v === undefined) return null
  if (typeof v === 'string') return v
  if (typeof v === 'number' || typeof v === 'boolean') return String(v)
  return null
}

function numOrNull(v: unknown): number | null {
  if (v === null || v === undefined) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim())
    return Number.isFinite(n) ? n : null
  }
  return null
}

const normalized = computed(() => normalizeToolContent(props.content))
const dataRecord = computed(() => asRecord(normalized.value.data))

// ── Parse outer envelope ─────────────────────────────────────────────────

type Behavior = 'list' | 'search' | 'search-within' | 'read' | 'denied' | 'error' | 'unknown'

const behavior = computed((): Behavior => {
  if (normalized.value.error ?? strOrNull(dataRecord.value.error)) return 'error'
  if (dataRecord.value.denied === true) return 'denied'
  const b = strOrNull(dataRecord.value.behavior)
  if (b === 'list' || b === 'search' || b === 'search-within' || b === 'read') return b
  return 'unknown'
})

const queryText = computed((): string | null => strOrNull(dataRecord.value.query))

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayBehavior = computed((): string | null => {
  if (behavior.value !== 'unknown') return behavior.value
  if (extractParam(props.parameters, 'query')) return 'search'
  if (extractParam(props.parameters, 'session_id')) return 'read'
  return null
})
const displayQuery = computed(
  (): string | null => queryText.value ?? extractParam(props.parameters, 'query'),
)
const displaySessionId = computed(
  (): string | null => sessionId.value ?? extractParam(props.parameters, 'session_id'),
)
const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const isRunning = computed(() => isEmptyContent(props.content) && displayBehavior.value !== null)

const sessionId = computed((): string | null => strOrNull(dataRecord.value.session_id))

/** Returned-page size (count of entries in *this* response). */
const count = computed((): number | null => numOrNull(dataRecord.value.count))

/**  * Total rows matching the WHERE clause (before LIMIT/OFFSET). Used by the LLM to know whether more
 * pages exist. We surface this too so the user can see "showing 20 of 47" at a glance. */
const totalCount = computed((): number | null => numOrNull(dataRecord.value.total_count))

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const offset = computed((): number | null => numOrNull(dataRecord.value.offset))

const order = computed((): string | null => strOrNull(dataRecord.value.order))

const errorMessage = computed(
  (): string | null => normalized.value.error ?? strOrNull(dataRecord.value.error),
)

const deniedSessionId = computed((): string | null => strOrNull(dataRecord.value.session_id))

const deniedMessage = computed((): string | null => strOrNull(dataRecord.value.message))

// ── Parse entries ────────────────────────────────────────────────────────

const listSessions = computed((): WorkspaceSession[] => {
  const results: WorkspaceSession[] = []
  const raw = dataRecord.value.sessions
  if (!Array.isArray(raw)) return results
  for (const item of raw) {
    const r = asRecord(item)
    results.push({
      id: typeof r.id === 'string' ? r.id : '',
      name: typeof r.name === 'string' ? r.name : '',
      status: typeof r.status === 'string' ? r.status : '',
      message_count: numOrNull(r.message_count) ?? 0,
      last_activity: strOrNull(r.last_activity) ?? undefined,
      preview: typeof r.preview === 'string' ? r.preview : '',
    })
  }
  return results
})

const searchEntries = computed((): SearchEntry[] => {
  const results: SearchEntry[] = []
  const raw = dataRecord.value.results
  if (!Array.isArray(raw)) return results
  for (const item of raw) {
    const r = asRecord(item)
    results.push({
      id: typeof r.id === 'string' ? r.id : '',
      session_id: typeof r.session_id === 'string' ? r.session_id : '',
      session_name: typeof r.session_name === 'string' ? r.session_name : '',
      role: typeof r.role === 'string' ? r.role : 'unknown',
      created_at: strOrNull(r.created_at) ?? undefined,
      snippet: typeof r.snippet === 'string' ? r.snippet : '',
    })
  }
  return results
})

/**  * Full message bodies the backend returns when the caller passes `message_ids`. Keyed by message id
 * so a hit can expand into its own body. The card previously ignored this field entirely. */
const fullContents = computed((): Map<string, FullContent> => {
  const map = new Map<string, FullContent>()
  const raw = dataRecord.value.full_contents
  if (!Array.isArray(raw)) return map
  for (const item of raw) {
    const r = asRecord(item)
    const id = typeof r.id === 'string' ? r.id : ''
    if (!id) continue
    const truncatedRaw = r.content_truncated
    map.set(id, {
      id,
      role: typeof r.role === 'string' ? r.role : 'unknown',
      content: typeof r.content === 'string' ? r.content : '',
      content_truncated: truncatedRaw === true || truncatedRaw === 1,
    })
  }
  return map
})

/**  * `YYYY-MM-DD HH:MM:SS` sorts lexicographically, which is why grouping by recency is only correct
 * now that the backend returns `created_iso` instead of a raw nanosecond epoch. */
function recencyKey(entry: SearchEntry): string {
  return entry.created_at ?? ''
}

const groupedEntries = computed((): SearchGroup[] => {
  const bySession = new Map<string, SearchEntry[]>()
  const order: string[] = []
  for (const entry of searchEntries.value) {
    // Hits with no session_id are still shown, under a single bucket.
    const key = entry.session_id || ''
    if (!bySession.has(key)) {
      bySession.set(key, [])
      order.push(key)
    }
    bySession.get(key)!.push(entry)
  }
  const groups: SearchGroup[] = order.map((key) => {
    const entries = bySession.get(key)!
    // Newest first inside a group.
    entries.sort((a, b) => recencyKey(b).localeCompare(recencyKey(a)))
    const newest = entries[0]
    return {
      key,
      sessionId: newest?.session_id ?? '',
      // Falls back to the id so a row is never nameless.
      sessionName: newest?.session_name || newest?.session_id || '(no session)',
      entries,
      newestAt: newest?.created_at,
    }
  })
  // Groups ordered by their own newest hit.
  groups.sort((a, b) => (b.newestAt ?? '').localeCompare(a.newestAt ?? ''))
  return groups
})

/**  * Stable test-id index per hit, taken from the ORIGINAL result order rather than the grouped render
 * order, so `search-entry-snippet-N` keeps meaning the same row it always did. */
const entryIndexById = computed((): Map<string, number> => {
  const map = new Map<string, number>()
  searchEntries.value.forEach((entry, i) => map.set(entry.id, i))
  return map
})

/** Role counts for THIS PAGE only — not the whole result set. */
const roleFacets = computed((): RoleFacet[] => {
  const counts = new Map<string, number>()
  for (const entry of searchEntries.value) {
    counts.set(entry.role, (counts.get(entry.role) ?? 0) + 1)
  }
  const order = ['user', 'assistant', 'tool']
  const facets: RoleFacet[] = []
  for (const role of order) {
    const n = counts.get(role)
    if (n) facets.push({ role, count: n })
    counts.delete(role)
  }
  // Any role outside the known three still gets a facet.
  for (const [role, n] of counts) facets.push({ role, count: n })
  return facets
})

const totalInPage = computed(() => searchEntries.value.length)

/** The card has no execute path, so a facet click cannot re-run the tool. It
 * copies a ready-made call the agent can paste as its next turn. */
function facetToolCall(role: string): string {
  const args: Record<string, string> = {}
  const q = queryText.value ?? displayQuery.value
  if (q) args.query = q
  args.role = role
  return JSON.stringify(args)
}

const copiedFacet = ref<string | null>(null)
let facetCopyTimer: ReturnType<typeof setTimeout> | null = null

async function copyFacetCall(e: Event, role: string): Promise<void> {
  e.stopPropagation()
  const payload = facetToolCall(role)
  try {
    await navigator.clipboard.writeText(payload)
  } catch {
    return
  }
  copiedFacet.value = role
  if (facetCopyTimer) clearTimeout(facetCopyTimer)
  facetCopyTimer = setTimeout(() => {
    copiedFacet.value = null
  }, 1200)
}

const readEntries = computed((): ReadEntry[] => {
  const results: ReadEntry[] = []
  const raw = dataRecord.value.message_index
  if (!Array.isArray(raw)) return results
  for (const item of raw) {
    const r = asRecord(item)
    const truncatedRaw = r.content_truncated
    results.push({
      id: typeof r.id === 'string' ? r.id : '',
      role: typeof r.role === 'string' ? r.role : 'unknown',
      created_at: strOrNull(r.created_at) ?? undefined,
      preview: typeof r.preview === 'string' ? r.preview : '',
      tool_call_id: strOrNull(r.tool_call_id) ?? undefined,
      tool_name: strOrNull(r.tool_name) ?? undefined,
      content: strOrNull(r.content) ?? undefined,
      content_truncated: truncatedRaw === true || truncatedRaw === 1,
    })
  }
  return results
})

// ── Header summary text ──────────────────────────────────────────────────

const summaryText = computed((): string => {
  if (errorMessage.value) return errorMessage.value
  if (behavior.value === 'denied') {
    return deniedSessionId.value
      ? `denied · ${truncateMiddle(deniedSessionId.value, 32)} not in your workspace`
      : 'denied · session not in your workspace'
  }

  const parts: string[] = []
  const b = behavior.value !== 'unknown' ? behavior.value : displayBehavior.value
  if (b === 'list') {
    parts.push('workspace sessions')
  } else if (b === 'search' || b === 'search-within') {
    parts.push(b === 'search-within' ? 'search within session' : 'workspace search')
    const q = queryText.value ?? displayQuery.value
    if (q) parts.push(`"${truncateMiddle(q, 48)}"`)
    const sid = sessionId.value ?? displaySessionId.value
    if (b === 'search-within' && sid) parts.push(truncateMiddle(sid, 32))
  } else if (b === 'read') {
    parts.push('session')
    const sid = sessionId.value ?? displaySessionId.value
    if (sid) parts.push(truncateMiddle(sid, 32))
    if (order.value) parts.push(`order=${order.value}`)
  } else {
    parts.push('read_workspace_session')
  }

  // Counters: "20 of 47" when paginated, just "47" when all fit.
  const c = count.value
  const t = totalCount.value
  if (c !== null && t !== null && t !== c) {
    parts.push(`${c} of ${t}`)
  } else if (c !== null) {
    parts.push(`${c} ${c === 1 ? 'entry' : 'entries'}`)
  }

  return parts.join(' · ')
})

const isError = computed(() => !!errorMessage.value)
const isDenied = computed(() => behavior.value === 'denied')
const hasEntries = computed(() => {
  if (behavior.value === 'list') return listSessions.value.length > 0
  if (behavior.value === 'search' || behavior.value === 'search-within')
    return searchEntries.value.length > 0
  return readEntries.value.length > 0
})
const hasArgs = computed(() => {
  const v = (props.parameters ?? '').trim()
  return v !== '' && v !== '{}'
})

// ── Actions ──────────────────────────────────────────────────────────────

const toggle = () => {
  if (hasEntries.value || isError.value || isDenied.value || hasArgs.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(id)
}

// Per-read-entry "show full content" toggle. We only show the
// full <content> when the user explicitly expands it — keeps the
// bubble compact even when one entry happens to be huge.
const expandedContentIds = ref<Set<string>>(new Set())
const isContentExpanded = (id: string): boolean => expandedContentIds.value.has(id)
const toggleContent = (id: string): void => {
  const next = new Set(expandedContentIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedContentIds.value = next
}

// ── Helpers ──────────────────────────────────────────────────────────────

/** Truncate `s` to `max` chars, keeping both ends (more useful for
 *  long paths/queries than a pure tail ellipsis). */
function truncateMiddle(s: string, max: number): string {
  if (s.length <= max) return s
  const half = Math.max(2, Math.floor((max - 1) / 2))
  return `${s.slice(0, half)}…${s.slice(s.length - half)}`
}

/** Split an FTS5 snippet into (text, isMatch) segments for `<mark>` rendering. The backend calls
 * `snippet(messages_fts, 0, '[', ']', '...', 10)`, so a real snippet wraps matches in BARE brackets
 * — `...a [portal] that refuses...` — and contains no tags at all. */

/** `[match]` / `[/match]` is still accepted because tool results persisted before this card learned
 * the bare format may carry it. */

/** A bracket span whose text contains a literal `[` (e.g. `[xdg-[portal]`) is split at the LAST
 * inner `[`, so the surrounding text stays visible instead of being highlighted wholesale. */
function parseSnippet(snippet: string): { text: string; match: boolean }[] {
  const out: { text: string; match: boolean }[] = []
  let inMatch = false

  const emit = (text: string, match: boolean): void => {
    if (!text) return
    const last = out[out.length - 1]
    if (last && last.match === match) last.text += text
    else out.push({ text, match })
  }

  let i = 0
  while (i < snippet.length) {
    const open = snippet.indexOf('[', i)
    if (open === -1) {
      emit(snippet.slice(i), inMatch)
      break
    }
    emit(snippet.slice(i, open), inMatch)

    const close = snippet.indexOf(']', open + 1)
    if (close === -1) {
      // Unterminated bracket — the rest is plain text.
      emit(snippet.slice(open), inMatch)
      break
    }

    const inner = snippet.slice(open + 1, close)
    if (inner === '/match') {
      inMatch = false
      i = close + 1
      continue
    }
    if (inner === 'match') {
      inMatch = true
      i = close + 1
      continue
    }

    const nested = inner.lastIndexOf('[')
    if (nested !== -1) {
      emit(inner.slice(0, nested + 1), false)
      emit(inner.slice(nested + 1), true)
    } else {
      emit(inner, true)
    }
    i = close + 1
  }
  return out
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="isError ? 'border-red-500/50 opacity-90' : ''"
    data-testid="read-workspace-session"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense"
        >read_workspace_session</span
      >
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="summaryText"
      >
        {{ summaryText }}
      </span>

      <!-- "showing N of M" badge when paginated -->
      <span
        v-if="count !== null && totalCount !== null && totalCount !== count"
        class="text-micro font-medium px-1.5 py-0.5 rounded bg-violet-500/10 text-[var(--color-violet)] shrink-0"
        :title="`Page contains ${count} entries out of ${totalCount} total matches`"
        data-testid="read-workspace-session-page-badge"
      >
        {{ count }} of {{ totalCount }}
      </span>

      <span v-if="isError" class="text-red-500 text-micro font-medium shrink-0"> Error </span>

      <span v-if="isDenied" class="text-yellow-500 text-micro font-medium shrink-0"> Denied </span>

      <span
        v-if="isRunning"
        data-testid="read-workspace-session-running"
        class="text-micro text-yellow-500 animate-pulse shrink-0"
        >running…</span
      >

      <span
        v-if="hasEntries || isError || isDenied || hasArgs"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-body shrink-0"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Error body — always visible (not gated by isExpanded) so the
         user sees the failure without an extra click. -->
    <div
      v-if="isError"
      class="border-t border-[var(--color-border)] px-3 py-2 text-red-500 text-meta break-words"
      data-testid="read-workspace-session-error"
    >
      {{ errorMessage }}
    </div>

    <!-- Denied body — always visible. The target session is outside the
         caller's workspace; no content is ever rendered here. -->
    <div
      v-else-if="isDenied"
      class="border-t border-[var(--color-border)] px-3 py-2 text-yellow-500 text-meta break-words"
      data-testid="read-workspace-session-denied"
    >
      {{ deniedMessage ?? 'Session is not in your workspace.' }}
      <span v-if="deniedSessionId" class="text-[var(--semantic-text-muted)]"
        >({{ deniedSessionId }})</span
      >
    </div>

    <!-- Empty-result hint — always visible when there's no error but also
         no entries. Saves the user a click to discover "no results". -->
    <div
      v-else-if="!hasEntries"
      class="border-t border-[var(--color-border)] px-3 py-4 text-center text-[var(--semantic-text-muted)] text-dense"
      data-testid="read-workspace-session-empty"
    >
      <template v-if="behavior === 'list'"> No other sessions in your workspace </template>
      <template v-else-if="behavior === 'search' || behavior === 'search-within'">
        No matches for "{{ queryText }}"
      </template>
      <template v-else> No messages in {{ sessionId }} </template>
    </div>

    <!-- Entry list — only when expanded and there are entries. -->
    <div
      v-if="isExpanded && hasEntries && !isError && !isDenied"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- behavior="list": workspace sessions -->
      <ul
        v-if="behavior === 'list'"
        class="divide-y divide-[var(--color-border)]"
        data-testid="read-workspace-session-list-entries"
      >
        <li
          v-for="(session, idx) in listSessions"
          :key="session.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="read-workspace-session-list-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Session name -->
            <span
              class="font-semibold text-[var(--semantic-text)] text-dense truncate max-w-[200px]"
              :title="session.name || session.id"
              :data-testid="`list-entry-name-${idx}`"
            >
              {{ session.name || session.id }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code class="entry-id" :title="session.id" :data-testid="`list-entry-id-${idx}`">
                {{ session.id }}
              </code>
              <button
                class="copy-btn"
                @click="(e) => copyId(e, session.id)"
                title="Copy session id"
              >
                ⎘
              </button>
            </div>

            <!-- Status -->
            <span v-if="session.status" class="text-[var(--semantic-text-dim)] text-micro shrink-0">
              {{ session.status }}
            </span>

            <!-- Message count -->
            <span
              class="text-[var(--semantic-text-dim)] text-micro shrink-0"
              :title="`${session.message_count} messages`"
            >
              {{ session.message_count }} msgs
            </span>

            <!-- Last activity -->
            <span
              v-if="session.last_activity"
              class="text-[var(--semantic-text-dim)] text-micro shrink-0"
              :title="`Last activity ${session.last_activity}`"
            >
              {{ session.last_activity }}
            </span>
          </div>

          <!-- Preview -->
          <p
            v-if="session.preview"
            class="mt-1 ml-0 text-meta text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`list-entry-preview-${idx}`"
          >
            {{ session.preview }}
          </p>
        </li>
      </ul>

      <!-- behavior="search" | "search-within": FTS results, grouped by session -->
      <div
        v-else-if="behavior === 'search' || behavior === 'search-within'"
        data-testid="read-workspace-session-search-entries"
      >
        <div
          v-for="group in groupedEntries"
          :key="group.key || '__no_session__'"
          class="search-group"
          :data-testid="`search-group-${group.key || 'none'}`"
        >
          <div class="search-group-header">
            <button
              v-if="group.sessionId"
              class="search-group-name"
              :title="`Open session ${group.sessionId}`"
              :data-testid="`search-group-open-${group.key}`"
              @click="openSession(group.sessionId)"
            >
              {{ group.sessionName }}
            </button>
            <span v-else class="search-group-name" data-testid="search-group-open-none">
              {{ group.sessionName }}
            </span>
            <span class="text-micro text-[var(--semantic-text-dim)] shrink-0">
              {{ group.entries.length }} {{ group.entries.length === 1 ? 'hit' : 'hits' }}
            </span>
            <span
              v-if="group.newestAt"
              class="text-micro text-[var(--semantic-text-dim)] shrink-0"
              :title="`Newest hit at ${group.newestAt}`"
            >
              {{ group.newestAt }}
            </span>
          </div>

          <ul class="divide-y divide-[var(--color-border)]">
            <li
              v-for="entry in group.entries"
              :key="entry.id || `${group.key}-${entry.snippet}`"
              class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
              data-testid="read-workspace-session-search-entry"
            >
              <div class="flex items-start gap-2 min-w-0">
                <!-- Role badge -->
                <span
                  class="role-badge shrink-0"
                  :class="`role-${entry.role}`"
                  :data-testid="`search-entry-role-${entryIndexById.get(entry.id)}`"
                >
                  {{ entry.role }}
                </span>

                <!-- ID + copy -->
                <div class="flex items-center gap-1 min-w-0 shrink-0">
                  <code
                    class="entry-id"
                    :title="entry.id"
                    :data-testid="`search-entry-id-${entryIndexById.get(entry.id)}`"
                  >
                    {{ entry.id }}
                  </code>
                  <button
                    class="copy-btn"
                    @click="(e) => copyId(e, entry.id)"
                    title="Copy message id"
                  >
                    ⎘
                  </button>
                </div>

                <!-- Timestamp -->
                <span
                  v-if="entry.created_at"
                  class="text-[var(--semantic-text-dim)] text-micro shrink-0"
                  :title="`Created at ${entry.created_at}`"
                >
                  {{ entry.created_at }}
                </span>
              </div>

              <!-- Snippet, FTS match wrapped in bare brackets -->
              <p
                v-if="entry.snippet"
                class="mt-1 ml-0 text-meta text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
                :data-testid="`search-entry-snippet-${entryIndexById.get(entry.id)}`"
              >
                <template v-for="(seg, segIdx) in parseSnippet(entry.snippet)" :key="segIdx">
                  <mark v-if="seg.match" class="bg-yellow-500/30 text-inherit rounded px-0.5">
                    {{ seg.text }}
                  </mark>
                  <span v-else>{{ seg.text }}</span>
                </template>
              </p>

              <!-- Full body, present only when the caller passed message_ids -->
              <div
                v-if="fullContents.get(entry.id)"
                class="mt-1"
                :data-testid="`search-entry-full-${entryIndexById.get(entry.id)}`"
              >
                <button
                  class="content-toggle"
                  :data-testid="`search-entry-toggle-full-${entryIndexById.get(entry.id)}`"
                  @click="toggleContent(entry.id)"
                >
                  <span class="content-toggle-icon">
                    {{ isContentExpanded(entry.id) ? '▼' : '▶' }}
                  </span>
                  <span>
                    {{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}
                    <span
                      v-if="fullContents.get(entry.id)?.content_truncated"
                      class="text-orange-500"
                      title="Backend truncated this content to fit context budget"
                    >
                      (truncated)
                    </span>
                  </span>
                </button>
                <pre
                  v-if="isContentExpanded(entry.id)"
                  class="content-body"
                  :data-testid="`search-entry-content-${entryIndexById.get(entry.id)}`"
                  >{{ fullContents.get(entry.id)?.content }}</pre>
              </div>
            </li>
          </ul>
        </div>

        <!-- Role counts for THIS PAGE. Not the whole result set. -->
        <div
          v-if="roleFacets.length"
          class="facet-footer"
          data-testid="read-workspace-session-role-facets"
        >
          <span class="text-micro text-[var(--semantic-text-dim)]">in this page</span>
          <button
            v-for="facet in roleFacets"
            :key="facet.role"
            class="facet"
            :class="{ 'facet-copied': copiedFacet === facet.role }"
            :title="`Copy a read_workspace_session call filtered to role=${facet.role}`"
            :data-testid="`role-facet-${facet.role}`"
            @click="copyFacetCall($event, facet.role)"
          >
            {{ facet.role }} {{ facet.count }}
          </button>
          <span class="text-micro text-[var(--semantic-text-dim)] ml-auto">
            {{ totalInPage }} of {{ totalCount ?? totalInPage }}
          </span>
        </div>
      </div>

      <!-- behavior="read": message index -->
      <ul
        v-else
        class="divide-y divide-[var(--color-border)]"
        data-testid="read-workspace-session-read-entries"
      >
        <li
          v-for="(entry, idx) in readEntries"
          :key="entry.id || idx"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="read-workspace-session-read-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              :data-testid="`read-entry-role-${idx}`"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code class="entry-id" :title="entry.id" :data-testid="`read-entry-id-${idx}`">
                {{ entry.id }}
              </code>
              <button class="copy-btn" @click="(e) => copyId(e, entry.id)" title="Copy message id">
                ⎘
              </button>
            </div>

            <!-- Timestamp -->
            <span
              v-if="entry.created_at"
              class="text-[var(--semantic-text-dim)] text-micro shrink-0"
              :title="`Created at ${entry.created_at}`"
            >
              {{ entry.created_at }}
            </span>

            <!-- Tool extras (only for tool role) -->
            <span
              v-if="entry.tool_call_id"
              class="tool-pill"
              :title="`Tool call id: ${entry.tool_call_id}`"
              :data-testid="`read-entry-tool-call-id-${idx}`"
            >
              {{ entry.tool_call_id }}
            </span>
            <span
              v-if="entry.tool_name"
              class="tool-pill tool-name-pill"
              :title="`Tool: ${entry.tool_name}`"
              :data-testid="`read-entry-tool-name-${idx}`"
            >
              {{ entry.tool_name }}
            </span>
          </div>

          <!-- Preview (always present when not in error) -->
          <p
            v-if="entry.preview"
            class="mt-1 ml-0 text-meta text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :data-testid="`read-entry-preview-${idx}`"
          >
            {{ entry.preview }}
          </p>

          <!-- Full content (only present when caller passed message_ids) -->
          <div v-if="entry.content" class="mt-1">
            <button
              class="content-toggle"
              type="button"
              :data-testid="`read-entry-toggle-content-${idx}`"
              @click="toggleContent(entry.id)"
            >
              <span class="content-toggle-icon">{{ isContentExpanded(entry.id) ? '▼' : '▶' }}</span>
              <span>
                {{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}
                <span
                  v-if="entry.content_truncated"
                  class="text-orange-500"
                  title="Backend truncated this content to fit context budget"
                >
                  (truncated)
                </span>
              </span>
            </button>
            <pre
              v-if="isContentExpanded(entry.id)"
              class="content-body"
              :data-testid="`read-entry-content-${idx}`"
              >{{ entry.content }}</pre>
          </div>
        </li>
      </ul>
      <ToolParameters :parameters="parameters" />
    </div>
    <div v-if="isExpanded && !hasEntries && !isError && !isDenied">
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

<style scoped>
/* Mirrors the role-badge / pill styles in ReadCompactedMessages.vue.
   Kept local (scoped) so the styles don't leak; if a third component
   needs them, hoist to a shared `tool-card-styles.css` later. */
.role-badge {
  font-size: var(--text-micro);
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 2px 6px;
  border-radius: 4px;
  min-width: 64px;
  text-align: center;
}

.role-user {
  background-color: rgba(34, 197, 94, 0.15);
  color: rgb(34, 197, 94);
}

.role-assistant {
  background-color: rgba(99, 102, 241, 0.15);
  color: rgb(99, 102, 241);
}

.role-tool {
  background-color: rgba(234, 179, 8, 0.15);
  color: rgb(234, 179, 8);
}

.role-unknown {
  background-color: var(--semantic-card-bg);
  color: var(--semantic-text-muted);
}

.entry-id {
  font-family: monospace;
  font-size: var(--text-micro);
  color: var(--semantic-text-dim);
  max-width: 100px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.copy-btn {
  padding: 0 2px;
  border: none;
  background: transparent;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
}

.group:hover .copy-btn {
  opacity: 1;
}

.copy-btn:hover {
  color: var(--color-violet);
}

.tool-pill {
  font-family: monospace;
  font-size: var(--text-micro);
  background-color: var(--semantic-card-bg);
  padding: 1px 5px;
  border-radius: 3px;
  color: var(--semantic-text-dim);
  white-space: nowrap;
}

.tool-name-pill {
  background-color: rgba(99, 102, 241, 0.12);
  color: rgb(99, 102, 241);
}

.content-toggle {
  background: none;
  border: none;
  cursor: pointer;
  font: inherit;
  font-size: var(--text-micro);
  font-weight: 600;
  color: var(--semantic-text-muted);
  padding: 0;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  text-transform: uppercase;
  letter-spacing: 0.4px;
}

.content-toggle:hover {
  color: var(--color-violet);
}

.content-toggle-icon {
  font-size: var(--text-micro);
  width: 10px;
  text-align: center;
}

.content-body {
  margin: 6px 0 0 0;
  padding: 8px 10px;
  background-color: var(--semantic-card-bg);
  border-radius: 4px;
  border: 1px solid var(--color-border);
  font-family: monospace;
  font-size: var(--text-meta);
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 320px;
  overflow-y: auto;
}

/* Search results grouped by session. The header is the only place a
   conversation is named, so it carries the session title in full. */
.search-group {
  border-bottom: 1px solid var(--color-border);
}

.search-group:last-of-type {
  border-bottom: none;
}

.search-group-header {
  display: flex;
  align-items: center;
  gap: 1px;
  padding: 4px 8px;
  background: var(--semantic-card-bg);
}

.search-group-name {
  flex: 1;
  min-width: 0;
  text-align: left;
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--semantic-text);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
}

.search-group-name:hover {
  color: var(--color-violet);
  text-decoration: underline;
}

/* Role facets. Counts are page-scoped, and the footer says so. */
.facet-footer {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
  padding: 5px 8px;
  border-top: 1px solid var(--color-border);
  font-size: var(--text-micro);
}

.facet {
  font-family: inherit;
  font-size: var(--text-micro);
  color: var(--semantic-text-muted);
  background: none;
  border: none;
  padding: 0;
  cursor: pointer;
}

.facet:hover {
  color: var(--color-violet);
}

.facet-copied {
  color: var(--color-violet);
  font-weight: 600;
}
</style>

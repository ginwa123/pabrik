<template>
  <div
    class="compaction-card"
    data-testid="compaction-card"
    :data-open="expanded ? 'true' : 'false'"
  >
    <button
      class="compaction-head"
      data-testid="compaction-toggle"
      type="button"
      aria-label="Conversation Compaction"
      :aria-expanded="expanded ? 'true' : 'false'"
      @click="toggleExpanded"
    >
      <UiIcon name="box" class="compaction-icon" size-class="w-4 h-4" />
      <span class="compaction-title">
        Compacted
        <span data-testid="compaction-count">
          {{ entries.length }} message{{ entries.length === 1 ? '' : 's' }}
        </span>
      </span>
      <span class="compaction-facts">
        <span v-if="workDir?.branch" class="fact">{{ workDir.branch }}</span>
        <span v-if="workDir?.branch && clock" class="fact-sep">·</span>
        <span v-if="clock" class="fact">{{ clock }}</span>
      </span>
      <span class="compaction-chevron" aria-hidden="true">
        <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.4">
          <path d="M2.5 4.5 6 8l3.5-3.5" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </span>
    </button>

    <div v-show="expanded" class="compaction-body">
      <section v-if="plan" class="compaction-plan" data-testid="compaction-plan">
        <div class="section-heading">
          <h4 class="compaction-section-title">Carried forward</h4>
          <span v-if="plan.updated_at" class="section-note"
            >plan updated {{ plan.updated_at }}</span
          >
        </div>
        <div class="plan-frame">
          <pre
            class="plan-content"
            :class="{ 'is-open': planOpen }"
            data-testid="compaction-plan-content"
            >{{ plan.markdown }}</pre>
        </div>
        <div v-if="planIsLong" class="plan-toggle-row">
          <button
            class="text-toggle"
            data-testid="compaction-plan-toggle"
            type="button"
            @click="togglePlan"
          >
            {{ planOpen ? 'Show less' : 'Show the whole plan' }}
          </button>
        </div>
      </section>

      <section
        v-if="workdirRows.length > 0"
        class="compaction-workdir"
        data-testid="compaction-workdir"
      >
        <div class="section-heading">
          <h4 class="compaction-section-title">Where</h4>
        </div>
        <div class="workdir-line">
          <template v-for="row in workdirRows" :key="row.testid">
            <span class="workdir-label">{{ row.label }}</span>
            <span class="workdir-path" :data-testid="row.testid">{{ row.value }}</span>
          </template>
          <span v-if="workDir?.head" class="workdir-chip">{{ workDir.head }}</span>
          <span
            v-if="dirtySummary"
            class="workdir-chip dirty"
            data-testid="compaction-workdir-dirty"
          >
            {{ dirtySummary }}
          </span>
        </div>
      </section>

      <section class="compaction-index" data-testid="compaction-index">
        <div class="section-heading">
          <h4 class="compaction-section-title">Dropped</h4>
          <button
            v-if="entries.length > MAX_ENTRIES_VISIBLE"
            class="text-toggle"
            data-testid="compaction-show-more"
            type="button"
            @click="toggleShowAll"
          >
            {{ showAll ? 'Show fewer' : `Show all ${entries.length}` }}
          </button>
        </div>
        <div v-if="roleCounts.length > 0" class="role-counts">
          <span v-for="count in roleCounts" :key="count.role" class="role-count">
            <span :class="['role-dot', `role-${count.role}`]" aria-hidden="true"></span>
            {{ count.role }} {{ count.count }}
          </span>
          <span class="section-note index-note">
            full history readable with <code>read_workspace_session</code>
          </span>
        </div>
        <ul class="compaction-entries" :class="{ 'is-open': showAll }">
          <li
            v-for="(entry, idx) in visibleEntries"
            :key="entry.id || `entry-${idx}`"
            :class="['compaction-entry', `entry-role-${entry.role}`]"
            data-testid="compaction-entry"
          >
            <span
              :class="['role-badge', `role-${entry.role}`]"
              :aria-label="entry.role || 'unknown'"
              data-testid="entry-role"
            >
              {{ entry.role || 'unknown' }}
            </span>
            <code v-if="entry.id" class="entry-id" :title="entry.id">{{ entry.id }}</code>
            <span class="entry-preview" :title="entry.preview">{{ entry.preview }}</span>
            <code
              v-if="entry.tool_call_id"
              class="entry-tool-call-id"
              :title="`Tool call id: ${entry.tool_call_id}`"
              data-testid="entry-tool-call-id"
            >
              {{ entry.tool_call_id }}
            </code>
          </li>
        </ul>
        <p v-if="omittedEntries > 0" class="section-note omitted-note" data-testid="compaction-omitted">
          {{ omittedEntries }} older message{{ omittedEntries === 1 ? '' : 's' }} rolled up but not
          listed.
        </p>
      </section>

      <section v-if="summary" class="compaction-summary" data-testid="compaction-summary">
        <button
          class="summary-toggle"
          data-testid="compaction-summary-toggle"
          type="button"
          :aria-expanded="summaryExpanded ? 'true' : 'false'"
          @click="toggleSummary"
        >
          <span class="summary-toggle-icon" aria-hidden="true">{{
            summaryExpanded ? '▼' : '▶'
          }}</span>
          <span>Compactor's summary</span>
        </button>
        <pre
          v-if="summaryExpanded"
          class="summary-content"
          data-testid="compaction-summary-content"
          >{{ summary }}</pre>
      </section>

      <footer v-if="hasMetadata" class="compaction-metadata" data-testid="compaction-metadata">
        <span v-if="metadata.session_id" class="metadata-item">
          session <code class="metadata-value">{{ metadata.session_id }}</code>
        </span>
        <span v-if="metadata.model" class="metadata-item">
          model <code class="metadata-value">{{ metadata.model }}</code>
        </span>
        <span v-if="metadata.compacted_at" class="metadata-item">
          at <code class="metadata-value">{{ metadata.compacted_at }}</code>
        </span>
      </footer>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

/** CompactionCard — the handoff envelope `compactMessageInMemoryNew` writes to the DB, drawn as a
 * one-line divider that opens: JSON envelopes carry the plan and the working directory, older XML
 * ones do not. Closed it costs 38px; the body stays in the DOM (`v-show`) so one click reveals it. */
const props = defineProps<{
  content: string
}>()

interface CompactionMetadata {
  session_id?: string
  model?: string
  compacted_at?: string
  original_count?: string
}

interface CompactionEntry {
  id: string
  role: string
  preview: string
  tool_call_id?: string
}

interface CompactionPlan {
  markdown: string
  updated_at?: string
}

interface CompactionWorkingDirectory {
  active_dir?: string
  session_cwd?: string
  git_worktree_cwd?: string
  branch?: string
  head?: string
  is_git_repo?: boolean
  dirty_total?: number
}

interface WorkdirRow {
  label: string
  value: string
  testid: string
}

type EnvelopeParse =
  | { kind: 'not_envelope' }
  | { kind: 'malformed' }
  | { kind: 'ok'; payload: Record<string, unknown> }

// Show more entries by default; .compaction-entries adds max-height + overflow-y so a 359-message
// compaction renders as a scrollable list rather than a 359-row wall. The "Show all" toggle remains
// for accessibility (keyboard-only users can expand without scrolling).
const MAX_ENTRIES_VISIBLE = 50
// A plan longer than this gets a "Show the whole plan" toggle; below it the clamp never bites.
const PLAN_FOLD_LINES = 12

const metadata = ref<CompactionMetadata>({})
const entries = ref<CompactionEntry[]>([])
const summary = ref<string>('')
const plan = ref<CompactionPlan | null>(null)
const workDir = ref<CompactionWorkingDirectory | null>(null)
const omittedEntries = ref(0)

const expanded = ref(false)
const planOpen = ref(false)
const showAll = ref(false)
const summaryExpanded = ref(false)

const hasMetadata = computed(
  () =>
    !!metadata.value.session_id ||
    !!metadata.value.model ||
    !!metadata.value.compacted_at ||
    !!metadata.value.original_count,
)

const visibleEntries = computed(() => {
  if (showAll.value) return entries.value
  return entries.value.slice(0, MAX_ENTRIES_VISIBLE)
})

/** `tool 31 · assistant 16 · user 3` — the mix stated once, instead of a 64px badge on every row. */
const roleCounts = computed((): { role: string; count: number }[] => {
  const byRole = new Map<string, number>()
  for (const entry of entries.value) {
    const role = entry.role || 'unknown'
    byRole.set(role, (byRole.get(role) ?? 0) + 1)
  }
  return [...byRole.entries()]
    .map(([role, count]) => ({ role, count }))
    .sort((a, b) => b.count - a.count || a.role.localeCompare(b.role))
})

/** One row per path that is actually different. A session that never bound a worktree used to print
 * the same directory three times (session cwd, active, worktree); the reader needs the difference,
 * not the repetition. */
const workdirRows = computed((): WorkdirRow[] => {
  const dir = workDir.value
  if (!dir) return []
  const rows: WorkdirRow[] = []
  const shown = new Set<string>()
  const push = (label: string, value: string | undefined, testid: string): void => {
    if (!value || shown.has(value)) return
    shown.add(value)
    rows.push({ label, value, testid })
  }
  push('session', dir.session_cwd, 'compaction-workdir-session')
  push('worktree', dir.git_worktree_cwd, 'compaction-workdir-worktree')
  push('active', dir.active_dir, 'compaction-workdir-active')
  return rows
})

const dirtySummary = computed(() => {
  const total = workDir.value?.dirty_total
  if (typeof total !== 'number' || total <= 0) return ''
  return total === 1 ? '1 uncommitted file' : `${total} uncommitted files`
})

/** `13:30` out of either stamp the backend writes (`2026-11-15T13:30:57.614Z` or
 * `2025-01-15 12:34:56`). The header has room for the clock, not the date. */
const clock = computed((): string => {
  const stamp = metadata.value.compacted_at
  if (!stamp) return ''
  const match = /(\d{1,2}:\d{2})/.exec(stamp)
  return match?.[1] ?? ''
})

const planIsLong = computed((): boolean => {
  const markdown = plan.value?.markdown ?? ''
  return markdown.split('\n').length > PLAN_FOLD_LINES
})

const toggleExpanded = () => {
  expanded.value = !expanded.value
}
const togglePlan = () => {
  planOpen.value = !planOpen.value
}
const toggleShowAll = () => {
  showAll.value = !showAll.value
}
const toggleSummary = () => {
  summaryExpanded.value = !summaryExpanded.value
}

/** Reads the JSON envelope the backend writes today. `not_envelope` sends the caller to the XML
 * reader, which is how envelopes written before the format change still render. */
const parseJsonEnvelope = (raw: string): EnvelopeParse => {
  const trimmed = raw.trim()
  if (!trimmed.startsWith('{"compact_messages"')) return { kind: 'not_envelope' }

  let decoded: unknown
  try {
    decoded = JSON.parse(trimmed)
  } catch {
    return { kind: 'malformed' }
  }

  const payload = (decoded as { compact_messages?: unknown } | null)?.compact_messages
  if (!payload || typeof payload !== 'object') return { kind: 'malformed' }
  return { kind: 'ok', payload: payload as Record<string, unknown> }
}

const applyPayload = (root: Record<string, unknown>): void => {
  const meta = asRecord(root.metadata)
  metadata.value = {
    session_id: asString(meta.session_id),
    model: asString(meta.model),
    compacted_at: asString(meta.compacted_at),
    original_count: meta.original_count === undefined ? undefined : String(meta.original_count),
  }

  const planRecord = asRecord(root.plan)
  const markdown = asString(planRecord.markdown)
  plan.value = markdown ? { markdown, updated_at: asString(planRecord.updated_at) } : null

  const dir = asRecord(root.working_directory)
  workDir.value = Object.keys(dir).length
    ? {
        active_dir: asString(dir.active_dir),
        session_cwd: asString(dir.session_cwd),
        git_worktree_cwd: asString(dir.git_worktree_cwd),
        branch: asString(dir.branch),
        head: asString(dir.head),
        is_git_repo: dir.is_git_repo === true,
        dirty_total: typeof dir.dirty_total === 'number' ? dir.dirty_total : undefined,
      }
    : null

  const index = Array.isArray(root.message_index) ? root.message_index : []
  entries.value = index.map((item) => {
    const entry = asRecord(item)
    return {
      id: asString(entry.id) ?? '',
      role: asString(entry.role) ?? 'unknown',
      preview: asString(entry.preview) ?? '',
      tool_call_id: asString(entry.tool_call_id),
    }
  })

  summary.value = asString(root.summary) ?? ''

  const truncated = asRecord(root.truncated_entries)
  omittedEntries.value = typeof truncated.count === 'number' ? truncated.count : 0
}

/** XML envelopes from before the JSON format change. Kept so old transcript rows still render. */
const parseXml = (raw: string): void => {
  // DOMParser reports malformed markup as a <parsererror> element rather than throwing, so the
  // check below is the whole guard — and a DB row truncated mid-write still renders the card.
  const doc = new DOMParser().parseFromString(raw, 'text/xml')
  if (doc.querySelector('parsererror')) {
    return
  }

  const root = doc.querySelector('compact_messages')
  if (!root) {
    return
  }

  // Metadata — direct child only, so a <metadata> tag inside the compactor's <summary> text cannot
  // match. `parent.children` + tag filter rather than `:scope > X`, which jsdom's XML parser does
  // not reliably support.
  const metadataEl = directChild(root, 'metadata')
  if (metadataEl) {
    metadata.value = {
      session_id: textOf(metadataEl, 'session_id'),
      model: textOf(metadataEl, 'model'),
      compacted_at: textOf(metadataEl, 'compacted_at'),
      original_count: textOf(metadataEl, 'original_count'),
    }
  }

  const indexEl = directChild(root, 'message_index')
  if (indexEl) {
    entries.value = directChildren(indexEl, 'entry').map((el) => ({
      id: textOf(el, 'id') ?? '',
      role: textOf(el, 'role') ?? 'unknown',
      preview: textOf(el, 'preview') ?? '',
      tool_call_id: textOf(el, 'tool_call_id') || undefined,
    }))
  }

  // The <plan> and <working_directory> sections exist only in JSON envelopes.
  const summaryEl = directChild(root, 'summary')
  if (summaryEl) {
    summary.value = (summaryEl.textContent ?? '').trim()
  }
}

const asRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}

const asString = (value: unknown): string | undefined => {
  if (typeof value !== 'string') return undefined
  return value.length > 0 ? value : undefined
}

const directChild = (parent: Element, tag: string): Element | null => {
  for (let i = 0; i < parent.children.length; i++) {
    const child = parent.children[i]
    if (child && child.tagName === tag) return child
  }
  return null
}

const directChildren = (parent: Element, tag: string): Element[] => {
  const result: Element[] = []
  for (let i = 0; i < parent.children.length; i++) {
    const child = parent.children[i]
    if (child && child.tagName === tag) result.push(child)
  }
  return result
}

const textOf = (parent: Element, tag: string): string | undefined => {
  const el = directChild(parent, tag)
  const t = el?.textContent?.trim()
  return t ? t : undefined
}

// Parse synchronously during setup rather than in onMounted, so the component is populated before
// it renders and the test does not depend on a full DOM lifecycle mount.
const parsedEnvelope = parseJsonEnvelope(props.content)
if (parsedEnvelope.kind === 'ok') {
  applyPayload(parsedEnvelope.payload)
} else if (parsedEnvelope.kind === 'not_envelope') {
  parseXml(props.content)
}
// `malformed`: recognised as an envelope but unreadable, so the card renders its empty state.
</script>

<style scoped src="./compactionCard.css"></style>

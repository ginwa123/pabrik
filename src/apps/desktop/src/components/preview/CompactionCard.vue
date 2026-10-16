<template>
  <div class="compaction-card" data-testid="compaction-card">
    <header class="compaction-header">
      <UiIcon name="box" class="compaction-icon" size-class="w-4.5 h-4.5" />
      <span class="compaction-title">Conversation Compaction</span>
      <span class="compaction-count" data-testid="compaction-count">
        {{ entries.length }} message{{ entries.length === 1 ? '' : 's' }} compacted
      </span>
    </header>

    <section v-if="plan" class="compaction-plan" data-testid="compaction-plan">
      <div class="section-heading">
        <h4 class="compaction-section-title">Task plan carried forward</h4>
        <span v-if="plan.updated_at" class="section-note">Updated {{ plan.updated_at }}</span>
      </div>
      <pre class="plan-content" data-testid="compaction-plan-content">{{ plan.markdown }}</pre>
    </section>

    <section v-if="workDir" class="compaction-workdir" data-testid="compaction-workdir">
      <div class="section-heading">
        <h4 class="compaction-section-title">Working directory</h4>
        <span v-if="workDir.branch" class="section-note">
          {{ workDir.branch }}{{ workDir.head ? ` · ${workDir.head}` : '' }}
        </span>
      </div>
      <dl class="workdir-list">
        <template v-if="workDir.git_worktree_cwd">
          <dt>Worktree</dt>
          <dd data-testid="compaction-workdir-worktree">{{ workDir.git_worktree_cwd }}</dd>
        </template>
        <template v-if="workDir.session_cwd">
          <dt>Session cwd</dt>
          <dd data-testid="compaction-workdir-session">{{ workDir.session_cwd }}</dd>
        </template>
        <template v-if="workDir.active_dir">
          <dt>Active</dt>
          <dd data-testid="compaction-workdir-active">{{ workDir.active_dir }}</dd>
        </template>
        <template v-if="dirtySummary">
          <dt>Changes</dt>
          <dd>{{ dirtySummary }}</dd>
        </template>
      </dl>
    </section>

    <section v-if="hasMetadata" class="compaction-metadata" data-testid="compaction-metadata">
      <div v-if="metadata.session_id" class="metadata-item">
        <span class="metadata-label">Session</span>
        <code class="metadata-value">{{ metadata.session_id }}</code>
      </div>
      <div v-if="metadata.model" class="metadata-item">
        <span class="metadata-label">Model</span>
        <code class="metadata-value">{{ metadata.model }}</code>
      </div>
      <div v-if="metadata.compacted_at" class="metadata-item">
        <span class="metadata-label">At</span>
        <code class="metadata-value">{{ metadata.compacted_at }}</code>
      </div>
    </section>

    <section class="compaction-index" data-testid="compaction-index">
      <div class="compaction-index-header">
        <h4 class="compaction-section-title">Dropped messages</h4>
        <button
          v-if="entries.length > MAX_ENTRIES_VISIBLE"
          class="show-more-btn"
          data-testid="compaction-show-more"
          type="button"
          @click="toggleShowAll"
        >
          {{ showAll ? 'Show fewer' : `Show all ${entries.length}` }}
        </button>
      </div>
      <p v-if="omittedEntries > 0" class="section-note" data-testid="compaction-omitted">
        {{ omittedEntries }} older message{{ omittedEntries === 1 ? '' : 's' }} rolled up but not
        listed; the full history is still in the session and readable with
        <code>read_workspace_session</code>.
      </p>
      <ul class="compaction-entries">
        <li
          v-for="(entry, idx) in visibleEntries"
          :key="entry.id || `entry-${idx}`"
          :class="['compaction-entry', `entry-role-${entry.role}`]"
          data-testid="compaction-entry"
        >
          <span :class="['role-badge', `role-${entry.role}`]" data-testid="entry-role">
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
    </section>

    <section v-if="summary" class="compaction-summary" data-testid="compaction-summary">
      <button
        class="summary-toggle"
        data-testid="compaction-summary-toggle"
        type="button"
        @click="toggleSummary"
      >
        <span class="summary-toggle-icon">{{ summaryExpanded ? '▼' : '▶' }}</span>
        <span>Compactor's summary</span>
        <span class="summary-toggle-hint">
          {{ summaryExpanded ? '(click to collapse)' : '(click to expand)' }}
        </span>
      </button>
      <pre
        v-if="summaryExpanded"
        class="summary-content"
        data-testid="compaction-summary-content"
        >{{ summary }}</pre>
    </section>
  </div>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

/** CompactionCard — renders the handoff envelope `compactMessageInMemoryNew` writes to the DB.
 * Envelopes written since the JSON format change carry the task plan and the working directory ahead
 * of the dropped-message index; earlier XML envelopes still render, without those two sections. */
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

type EnvelopeParse =
  | { kind: 'not_envelope' }
  | { kind: 'malformed' }
  | { kind: 'ok'; payload: Record<string, unknown> }

// Show more entries by default; .compaction-entries adds max-height + overflow-y so a 359-message
// compaction renders as a scrollable list rather than a 359-row wall. The "Show all" toggle remains
// for accessibility (keyboard-only users can expand without scrolling).
const MAX_ENTRIES_VISIBLE = 50

const metadata = ref<CompactionMetadata>({})
const entries = ref<CompactionEntry[]>([])
const summary = ref<string>('')
const plan = ref<CompactionPlan | null>(null)
const workDir = ref<CompactionWorkingDirectory | null>(null)
const omittedEntries = ref(0)

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

const dirtySummary = computed(() => {
  const total = workDir.value?.dirty_total
  if (typeof total !== 'number' || total <= 0) return ''
  return total === 1 ? '1 uncommitted file' : `${total} uncommitted files`
})

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

<style scoped>
.compaction-card {
  border: 1px solid var(--color-border);
  border-radius: 8px;
  padding: 12px;
  margin: 8px 0;
  background-color: var(--color-bg-elevated);
  font-family: inherit;
  font-size: var(--text-dense);
  color: var(--color-text);
  max-width: 100%;
  box-sizing: border-box;
}

.compaction-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
}

.compaction-icon {
  font-size: var(--text-title-sm);
  line-height: 1;
}

.compaction-title {
  flex: 1;
  font-weight: 600;
  font-size: var(--text-body);
}

.compaction-count {
  font-size: var(--text-meta);
  color: var(--color-text-dim);
  background-color: var(--color-bg);
  padding: 3px 8px;
  border-radius: 12px;
  white-space: nowrap;
}

.section-heading {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 8px;
  margin-bottom: 6px;
}

.section-note {
  font-size: var(--text-meta);
  color: var(--color-text-dim);
}

.compaction-plan {
  margin-bottom: 12px;
}

.plan-content {
  margin: 0;
  padding: 10px;
  background-color: var(--color-bg);
  border-radius: 4px;
  font-family: inherit;
  font-size: var(--text-dense);
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 280px;
  overflow-y: auto;
}

.compaction-workdir {
  margin-bottom: 12px;
}

.workdir-list {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 4px 10px;
  margin: 0;
  font-size: var(--text-dense);
}

.workdir-list dt {
  color: var(--color-text-dim);
}

.workdir-list dd {
  margin: 0;
  font-family: monospace;
  word-break: break-all;
}

.compaction-metadata {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 12px;
  padding: 8px 10px;
  background-color: var(--color-bg);
  border-radius: 4px;
}

.metadata-item {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.metadata-label {
  font-size: var(--text-meta);
  color: var(--color-text-dim);
}

.metadata-value {
  font-family: monospace;
  font-size: var(--text-dense);
  color: var(--color-text);
  word-break: break-all;
}

.compaction-section-title {
  margin: 0;
  font-size: var(--text-body);
  font-weight: 600;
  color: var(--color-text);
}

.compaction-index-header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 6px;
}

.show-more-btn {
  background: none;
  border: none;
  cursor: pointer;
  font: inherit;
  font-size: var(--text-meta);
  color: var(--color-accent, var(--color-violet));
  padding: 0;
  text-decoration: underline;
}

.show-more-btn:hover {
  opacity: 0.8;
}

.compaction-entries {
  list-style: none;
  padding: 0;
  margin: 0;
  background-color: var(--color-bg);
  border-radius: 4px;
  /* `overflow-y: auto` keeps a long entry list inside the card instead of
     pushing the chat viewport down by hundreds of pixels. `max-height` caps
     the visual size — with MAX_ENTRIES_VISIBLE = 50 the common case shows
     everything inline, and larger compactions scroll within the card. */
  max-height: 400px;
  overflow-y: auto;
}

.compaction-entry {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  font-size: var(--text-dense);
  min-width: 0;
}

.compaction-entry + .compaction-entry {
  margin-top: 1px;
}

.role-badge {
  font-size: var(--text-micro);
  font-weight: 600;
  padding: 2px 6px;
  border-radius: 4px;
  background-color: var(--color-bg-elevated);
  color: var(--color-text);
  min-width: 64px;
  text-align: center;
  flex-shrink: 0;
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
  background-color: var(--color-bg-elevated);
  color: var(--color-text-dim);
}

.entry-id {
  font-family: monospace;
  font-size: var(--text-micro);
  color: var(--color-text-dim);
  max-width: 100px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex-shrink: 0;
}

.entry-preview {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--color-text);
}

.entry-tool-call-id {
  font-family: monospace;
  font-size: var(--text-micro);
  background-color: var(--color-bg-elevated);
  padding: 1px 5px;
  border-radius: 3px;
  color: var(--color-text-dim);
  flex-shrink: 0;
}

.compaction-summary {
  margin-top: 12px;
}

.summary-toggle {
  background: none;
  border: none;
  cursor: pointer;
  font: inherit;
  font-size: var(--text-dense);
  font-weight: 600;
  color: var(--color-text);
  padding: 0;
  display: flex;
  align-items: center;
  gap: 6px;
  width: 100%;
  text-align: left;
}

.summary-toggle:hover {
  color: var(--color-accent, var(--color-violet));
}

.summary-toggle-icon {
  font-size: var(--text-micro);
  width: 12px;
  text-align: center;
  flex-shrink: 0;
}

.summary-toggle-hint {
  font-size: var(--text-micro);
  font-weight: 400;
  color: var(--color-text-dim);
  margin-left: auto;
}

.summary-content {
  margin: 8px 0 0 18px;
  padding: 10px;
  background-color: var(--color-bg);
  border-radius: 4px;
  font-family: inherit;
  font-size: var(--text-dense);
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 320px;
  overflow-y: auto;
}
</style>

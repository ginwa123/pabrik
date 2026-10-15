<template>
  <div class="compaction-card" data-testid="compaction-card">
    <header class="compaction-header" :class="{ 'compaction-header-clickable': true }">
      <UiIcon name="box" class="compaction-icon" size-class="w-4.5 h-4.5" />
      <span class="compaction-title">Conversation Compaction</span>
      <span class="compaction-count" data-testid="compaction-count">
        {{ entries.length }} message{{ entries.length === 1 ? '' : 's' }} compacted
      </span>
    </header>

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

/**
 * CompactionCard — renders the rich `<compact_messages>` envelope that
 * `compactMessageInMemoryNew` writes to the DB. Three sections:
 *   - <metadata>: session_id, model, compacted_at
 *   - <message_index>: id + role + preview (+ tool_call_id for tool results)
 *   - <summary>: the compactor's structured output (GOAL / CURRENT STATE / ...)
 *
 * The summary section is collapsed by default to keep the chat scannable;
 * users expand it on demand to see what the compactor extracted.
 *
 * The XML is parsed in-browser with `DOMParser` (works in jsdom + all
 * modern browsers). The envelope is small (≤ a few KB) so this is cheap.
 */
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
  created_at?: string
  preview: string
  tool_call_id?: string
  tool_name?: string
}

// Show more entries by default; the .compaction-entries style adds max-height + overflow-y so a
// 359-message compaction renders as a scrollable list rather than a 359-row wall. The "Show all"
// toggle remains for accessibility (keyboard-only users can expand without scrolling).
const MAX_ENTRIES_VISIBLE = 50

const metadata = ref<CompactionMetadata>({})
const entries = ref<CompactionEntry[]>([])
const summary = ref<string>('')

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

const toggleShowAll = () => {
  showAll.value = !showAll.value
}
const toggleSummary = () => {
  summaryExpanded.value = !summaryExpanded.value
}

const parse = (raw: string) => {
  // Defensive: don't crash on malformed XML. The Zig-side envelope is well-formed by construction,
  // but a DB row that got truncated mid-write (e.g. interrupted saveMessage) should still render
  // the card, even if some sections are empty.
  let doc: Document
  try {
    doc = new DOMParser().parseFromString(raw, 'text/xml')
  } catch {
    return
  }

  // Bail on parser errors (<parsererror> element). The card renders empty.
  if (doc.querySelector('parsererror')) {
    return
  }

  // <compact_messages> may or may not be the root. Some encoders wrap it
  // in an extra <div> or include a leading XML prolog. Use a tolerant
  // selector: any direct child of <compact_messages> matches the schema.
  const root = doc.querySelector('compact_messages')
  if (!root) {
    return
  }

  // Metadata — direct child only (avoids matching a <metadata> tag that might appear inside the
  // compactor's <summary> text).
  // We use `parent.children` + tag filter instead of `:scope > X` because the latter is not
  // reliably supported by jsdom's XML parser (and the project uses jsdom for component tests).
  const metadataEl = directChild(root, 'metadata')
  if (metadataEl) {
    metadata.value = {
      session_id: textOf(metadataEl, 'session_id'),
      model: textOf(metadataEl, 'model'),
      compacted_at: textOf(metadataEl, 'compacted_at'),
      original_count: textOf(metadataEl, 'original_count'),
    }
  }

  // Message index
  const indexEl = directChild(root, 'message_index')
  if (indexEl) {
    const entryEls = directChildren(indexEl, 'entry')
    entries.value = entryEls.map((el) => ({
      id: textOf(el, 'id') ?? '',
      role: textOf(el, 'role') ?? 'unknown',
      created_at: textOf(el, 'created_at') || undefined,
      preview: textOf(el, 'preview') ?? '',
      tool_call_id: textOf(el, 'tool_call_id') || undefined,
      tool_name: textOf(el, 'tool_name') || undefined,
    }))
  }

  // Summary
  const summaryEl = directChild(root, 'summary')
  if (summaryEl) {
    summary.value = (summaryEl.textContent ?? '').trim()
  }
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

// Parse synchronously during setup (rather than in onMounted) so the component is fully populated
// by the time it's rendered.
// This also makes the component testable without a full DOM lifecycle mount (vue-test-utils'
// `mount()` does call onMounted, but setup-time parsing is more deterministic).
parse(props.content)
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

.compaction-metadata {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 12px;
  padding: 8px 10px;
  background-color: var(--color-bg);
  border-radius: 4px;
  border: 1px solid var(--color-border-soft);
}

.metadata-item {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

.metadata-label {
  font-size: var(--text-micro);
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--color-text-dim);
}

.metadata-value {
  font-family: monospace;
  font-size: var(--text-dense);
  color: var(--color-text);
  word-break: break-all;
}

.compaction-section-title {
  margin: 0 0 6px 0;
  font-size: var(--text-meta);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--color-text-dim);
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
  border: 1px solid var(--color-border-soft);
  border-radius: 4px;
  /* `overflow: hidden` clipped the inner border-radius corners; switch
     to `overflow-y: auto` so a long entry list scrolls inside the card
     instead of pushing the chat viewport down by hundreds of pixels.
     `max-height` caps the visual size — combined with MAX_ENTRIES_VISIBLE
     = 50, the common case (≤50 entries) shows everything inline, and
     larger compactions scroll within the card. */
  max-height: 400px;
  overflow-y: auto;
}

.compaction-entry {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 10px;
  border-bottom: 1px solid var(--color-border-soft);
  font-size: var(--text-dense);
  min-width: 0;
}

.compaction-entry:last-child {
  border-bottom: none;
}

.role-badge {
  font-size: var(--text-micro);
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 2px 6px;
  border-radius: 4px;
  background-color: var(--color-bg);
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
  background-color: var(--color-bg);
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
  background-color: var(--color-bg);
  padding: 1px 5px;
  border-radius: 3px;
  color: var(--color-text-dim);
  flex-shrink: 0;
}

.compaction-summary {
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px solid var(--color-border-soft);
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
  border: 1px solid var(--color-border-soft);
  font-family: monospace;
  font-size: var(--text-meta);
  line-height: 1.5;
  white-space: pre-wrap;
  word-wrap: break-word;
  max-height: 320px;
  overflow-y: auto;
  margin-bottom: 0;
}
</style>

<script setup lang="ts">
import { computed, ref } from 'vue'
import { extractParam } from '../../helpers/extractParam'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent } from './_shared/toolOutputParser'

/** ReadCompactedMessages — renders the rich `<read_compacted_messages>` envelope returned by the
 * `read_compacted_messages` tool. */
interface MessageEntry {
  id: string
  role: string
  created_at?: string
  preview: string
  tool_call_id?: string
  tool_name?: string
  content?: string
}

const props = defineProps<{
  content: unknown
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// ── Parse the outer envelope ────────────────────────────────────────────────
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

const mode = computed((): 'index' | 'full' | 'unknown' => {
  const m = strOrNull(dataRecord.value.mode)
  if (!m) return 'unknown'
  return m === 'full' ? 'full' : 'index'
})

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayMode = computed((): string | null => {
  if (mode.value !== 'unknown') return mode.value
  return extractParam(props.parameters, 'mode')
})
const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const isRunning = computed(() => isEmptyContent(props.content) && displayMode.value !== null)

const sessionId = computed((): string | null => strOrNull(dataRecord.value.session_id))

const count = computed((): number | null => numOrNull(dataRecord.value.count))

const errorMessage = computed((): string | null => normalized.value.error ?? strOrNull(dataRecord.value.error))

// ── Parse the message index rows ───────────────────────────────────
const entries = computed((): MessageEntry[] => {
  const results: MessageEntry[] = []
  const raw = dataRecord.value.message_index ?? dataRecord.value.entries
  if (!Array.isArray(raw)) return results
  for (const item of raw) {
    const r = asRecord(item)
    results.push({
      id: typeof r.id === 'string' ? r.id : '',
      role: typeof r.role === 'string' ? r.role : 'unknown',
      created_at: strOrNull(r.created_at) ?? undefined,
      preview: typeof r.preview === 'string' ? r.preview : '',
      tool_call_id: strOrNull(r.tool_call_id) ?? undefined,
      tool_name: strOrNull(r.tool_name) ?? undefined,
      content: strOrNull(r.content) ?? undefined,
    })
  }
  return results
})

// ── Header summary text ─────────────────────────────────────────────────────
const summaryText = computed((): string => {
  if (errorMessage.value) return errorMessage.value

  const parts: string[] = []
  const effectiveMode = mode.value !== 'unknown' ? mode.value : displayMode.value
  parts.push(effectiveMode && effectiveMode !== 'unknown' ? `${effectiveMode} mode` : 'read')
  if (count.value !== null) {
    parts.push(`${count.value} ${count.value === 1 ? 'message' : 'messages'}`)
  }
  if (sessionId.value) {
    parts.push(sessionId.value)
  }
  return parts.join(' · ')
})

const isError = computed(() => !!errorMessage.value)
const hasEntries = computed(() => entries.value.length > 0)

// ── Actions ─────────────────────────────────────────────────────────────────
const toggle = () => {
  if (hasEntries.value || isError.value) {
    isExpanded.value = !isExpanded.value
  }
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(id)
}

// Per-entry "show full content" toggle (only meaningful in full mode).
const expandedContentIds = ref<Set<string>>(new Set())
const isContentExpanded = (id: string): boolean => expandedContentIds.value.has(id)
const toggleContent = (id: string): void => {
  // Reassign to trigger reactivity (Vue ref<Set> requires a new Set
  // instance for reactivity to detect the change).
  const next = new Set(expandedContentIds.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedContentIds.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="isError ? 'border-red-500/50 opacity-90' : ''"
    data-testid="read-compacted-messages"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">
        read_compacted_messages
      </span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="summaryText"
      >
        {{ summaryText }}
      </span>

      <span
        v-if="isError"
        class="text-red-500 text-micro font-medium shrink-0"
      >
        Error
      </span>

      <span v-if="isRunning" data-testid="read-compacted-messages-running" class="text-micro text-yellow-500 animate-pulse shrink-0">running…</span>

      <!-- Toggle indicator: hidden when there's nothing to expand -->
      <span
        v-if="hasEntries || isError"
        class="w-4 text-center text-[var(--semantic-text-muted)] text-body shrink-0"
      >
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <!-- Error body -->
      <div
        v-if="isError"
        class="px-3 py-2 text-red-500 text-meta break-words"
        data-testid="rcm-error"
      >
        {{ errorMessage }}
      </div>

      <!-- Empty result (valid response, 0 entries) -->
      <div
        v-else-if="!hasEntries"
        class="px-3 py-4 text-center text-[var(--semantic-text-muted)] text-dense"
        data-testid="rcm-empty"
      >
        No messages found
      </div>

      <!-- Entry list -->
      <ul
        v-else
        class="divide-y divide-[var(--color-border)]"
        data-testid="rcm-entries"
      >
        <li
          v-for="entry in entries"
          :key="entry.id || entry.preview"
          class="px-3 py-2 text-[var(--semantic-text)] hover:bg-violet-500/5"
          data-testid="rcm-entry"
        >
          <div class="flex items-start gap-2 min-w-0">
            <!-- Role badge -->
            <span
              class="role-badge shrink-0"
              :class="`role-${entry.role}`"
              data-testid="rcm-entry-role"
            >
              {{ entry.role }}
            </span>

            <!-- ID + copy -->
            <div class="flex items-center gap-1 min-w-0 shrink-0">
              <code
                class="entry-id"
                :title="entry.id"
                data-testid="rcm-entry-id"
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

            <!-- Tool extras (only for tool role) -->
            <span
              v-if="entry.tool_call_id"
              class="tool-pill"
              :title="`Tool call id: ${entry.tool_call_id}`"
              data-testid="rcm-entry-tool-call-id"
            >
              {{ entry.tool_call_id }}
            </span>
            <span
              v-if="entry.tool_name"
              class="tool-pill tool-name-pill"
              :title="`Tool: ${entry.tool_name}`"
              data-testid="rcm-entry-tool-name"
            >
              {{ entry.tool_name }}
            </span>
          </div>

          <!-- Preview -->
          <p
            v-if="entry.preview"
            class="mt-1 ml-0 text-meta text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            :title="entry.preview"
          >
            {{ entry.preview }}
          </p>

          <!-- Full content (only present in mode='full') -->
          <div v-if="entry.content" class="mt-1">
            <button
              class="content-toggle"
              type="button"
              :data-testid="`rcm-toggle-content-${entry.id}`"
              @click="toggleContent(entry.id)"
            >
              <span class="content-toggle-icon">{{ isContentExpanded(entry.id) ? '▼' : '▶' }}</span>
              <span>{{ isContentExpanded(entry.id) ? 'Hide content' : 'Show content' }}</span>
            </button>
            <pre
              v-if="isContentExpanded(entry.id)"
              class="content-body"
              data-testid="rcm-entry-content"
            >{{ entry.content }}</pre>
          </div>
        </li>
      </ul>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

<style scoped>
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
</style>
<!--
  UsedTools — tool output component for the `used_tools` agent tool.

  Replaces the raw-JSON fallback (`{"count":10,"tools":[{"name":"update_plan",…]}`)
  with a readable list of the tools equipped for this session.

  Wire shape (whole role=tool message in `message.content`; the standard
  `wrapToolOutput` envelope with the inner payload in `data`):
    Success:
      {"tool":"used_tools","parameters":{},"success":true,
       "data":{"count":N,"tools":[{"name":…,"description":…}, …]},
       "error":null,"v":1}
    Error:
      {"tool":"used_tools","parameters":{},"success":false,
       "data":null,"error":"used_tools failed: …","v":1}

  Self-contained `:message="msg"` idiom (same as GetPlan.vue / ListSubAgent.vue /
  UpdatePlan.vue): `used_tools` declares zero input parameters, so there is no
  `<parameters>` block worth threading and no `expanded` state worth sharing with
  the dispatcher. The component unwraps the envelope itself.

  `count` is the backend's own tally of `tools`. The rendered rows come from the
  array (the thing that actually has content), so a stale/absent `count` never
  desyncs the card from what is on screen.

  Header (always visible, via ToolCardHeader):
    `used_tools ✓` — primary "N tools equipped", right-meta "N mcp" when any
    `mcp_*` tool is equipped
    `used_tools ✓` — primary "No tools equipped" (count 0 / empty array)

  Expanded body (click header to toggle): a name/description filter box, then
  one row per tool — name (bold) + `mcp` chip for `mcp_*` tools + the FULL
  description (never truncated; the body itself is scrollable).
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { tryUnwrapToolOutput } from '../../helpers/unwrapToolOutput'

// Minimal shape we need from the parent. ChatView.vue defines a LOCAL
// `Message` interface (different from `api.Message`) so we declare just the
// fields we read — this keeps the component decoupled from whichever Message
// type the parent uses.
interface ToolMessageLike {
  id?: string
  role?: string
  content: string
  tool_name?: string
}

/** One equipped tool row. `description` may be '' (backend never promises text). */
interface ToolRow {
  name: string
  description: string
  /** True for `mcp_*` tools (equipped from a connected MCP server this session). */
  isMcp: boolean
}

interface ParsedUsedTools {
  /** True when neither the envelope nor the payload carried an error. */
  success: boolean
  /** True when the payload held no usable tool rows. */
  isEmpty: boolean
  rows: ToolRow[]
  error: string | null
}

const props = defineProps<{
  message: ToolMessageLike
}>()

const isExpanded = ref(false)
/** Case-insensitive substring filter over name + description. */
const filter = ref('')

function asRecord(v: unknown): Record<string, unknown> {
  if (typeof v === 'string') {
    try {
      const p: unknown = JSON.parse(v)
      return typeof p === 'object' && p !== null && !Array.isArray(p)
        ? (p as Record<string, unknown>)
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

/** Unwrap the message content to the inner payload record. Accepts the full JSON
 * envelope string (the real wire shape) or a bare payload JSON string
 * (defensive fallback for direct callers). Returns null when the content is
 * not parseable JSON at all. */
function payloadOf(
  content: string,
): { data: Record<string, unknown>; error: string | null } | null {
  const unwrapped = tryUnwrapToolOutput(content)
  if (unwrapped) {
    if (!unwrapped.success) return { data: {}, error: unwrapped.error ?? 'tool failed' }
    return { data: asRecord(unwrapped.data), error: null }
  }
  try {
    const parsed: unknown = JSON.parse(content)
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      const record = parsed as Record<string, unknown>
      return { data: record, error: strOrNull(record.error) }
    }
    return null
  } catch {
    return null
  }
}

const parsed = computed((): ParsedUsedTools => {
  const unwrapped = payloadOf(props.message.content)
  if (unwrapped === null) {
    return { success: false, isEmpty: false, rows: [], error: 'malformed tool output' }
  }
  const error = unwrapped.error ?? strOrNull(unwrapped.data.error)
  if (error !== null) {
    return { success: false, isEmpty: false, rows: [], error }
  }

  const rows: ToolRow[] = []
  const raw = unwrapped.data.tools
  if (Array.isArray(raw)) {
    for (const item of raw) {
      const r = asRecord(item)
      const name = strOrNull(r.name)
      // A row without a name is unusable — skip it rather than render a
      // blank line. `count` is NOT cross-checked: rows are the truth here.
      if (!name) continue
      rows.push({
        name,
        description: strOrNull(r.description) ?? '',
        isMcp: name.startsWith('mcp_'),
      })
    }
  }
  return { success: true, isEmpty: rows.length === 0, rows, error: null }
})

const mcpCount = computed(() => parsed.value.rows.filter((r) => r.isMcp).length)

/** Rows matching the filter box (empty filter → every row, unfiltered). */
const visibleRows = computed((): ToolRow[] => {
  const q = filter.value.trim().toLowerCase()
  if (!q) return parsed.value.rows
  return parsed.value.rows.filter(
    (r) => r.name.toLowerCase().includes(q) || r.description.toLowerCase().includes(q),
  )
})

const isFiltered = computed(() => filter.value.trim().length > 0)

const primaryLabel = computed((): string => {
  const n = parsed.value.rows.length
  if (n === 0) return 'No tools equipped'
  return `${n} tool${n === 1 ? '' : 's'} equipped`
})

const rightMeta = computed((): string | null => {
  if (!parsed.value.success) return 'error'
  return mcpCount.value > 0 ? `${mcpCount.value} mcp` : null
})

/** Copy value: just the names, one per line (descriptions are far too long). */
const copyValue = computed((): string => parsed.value.rows.map((r) => r.name).join('\n'))

const handleToggle = (next: boolean) => {
  isExpanded.value = next
  // A stale filter would otherwise hide every row on the next open.
  if (!next) filter.value = ''
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !parsed.success }"
    data-testid="used-tools"
  >
    <ToolCardHeader
      tool-name="used_tools"
      :primary="primaryLabel"
      :primary-title="primaryLabel"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :right-meta="rightMeta"
      :show-open-in-editor="false"
      :copy-value="copyValue"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
      data-testid="used-tools-body"
    >
      <!-- Error body — visible when expanded AND the call failed. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="used-tools-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Empty result (valid response, nothing equipped for this session). -->
      <div
        v-else-if="parsed.isEmpty"
        class="px-3 py-3 text-center text-[var(--semantic-text-muted)] text-dense"
        data-testid="used-tools-empty"
      >
        No tools equipped for this session.
      </div>

      <template v-else>
        <div class="flex items-center gap-2 px-2 py-1.5">
          <input
            v-model="filter"
            type="text"
            placeholder="Filter by name or description…"
            spellcheck="false"
            class="min-w-0 flex-1 rounded border border-[var(--color-border)] bg-transparent px-1.5 py-0.5 text-dense text-[var(--semantic-text)] placeholder:text-[var(--semantic-text-muted)] focus:outline-none focus:border-[var(--color-violet)]"
            data-testid="used-tools-filter"
          />
          <span
            v-if="isFiltered"
            class="text-micro text-[var(--semantic-text-muted)] shrink-0"
            data-testid="used-tools-filter-count"
          >
            {{ visibleRows.length }}/{{ parsed.rows.length }}
          </span>
        </div>

        <div
          v-if="isFiltered && visibleRows.length === 0"
          class="px-3 py-3 text-center text-[var(--semantic-text-muted)] text-dense"
          data-testid="used-tools-no-match"
        >
          No tool matches "{{ filter.trim() }}".
        </div>

        <div v-else class="max-h-96 overflow-auto">
          <div
            v-for="row in visibleRows"
            :key="row.name"
            class="px-2 py-1.5 border-b border-[var(--color-border)] last:border-b-0"
            data-testid="used-tools-row"
          >
            <div class="flex items-center gap-1.5 flex-wrap">
              <span class="font-semibold text-[var(--semantic-text)] break-all">{{
                row.name
              }}</span>
              <span
                v-if="row.isMcp"
                class="text-micro px-1 rounded bg-green-500/10 text-green-500"
                data-testid="used-tools-mcp-chip"
                >mcp</span
              >
            </div>
            <div
              v-if="row.description"
              class="mt-0.5 text-[var(--semantic-text-muted)] whitespace-pre-wrap break-words"
            >
              {{ row.description }}
            </div>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>

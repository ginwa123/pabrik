<!--
  ListSubAgent — tool output component for the `list_sub_agent` agent tool.

  Renders the XML envelope produced by the backend `list_sub_agent` tool.
  Purely presentational: no API calls, no store mutations, no navigation.

  Wire shape (whole role=tool message in `message.content`, inner envelope
  parsed here — self-contained `:message="msg"` idiom, copied from
  GetPlan.vue):
    Populated:
      <list_sub_agent><profile>P</profile><count>N</count><sub_agents>
        <sub_agent><name>..</name><model>..</model><url_style>..</url_style>
        <thinking>..</thinking><temperature>..</temperature>
        [<max_capacity_tokens>..</max_capacity_tokens>]
        [<compaction_threshold_percent>..</compaction_threshold_percent>]
        [<thinking_budget_tokens>..</thinking_budget_tokens>]
        [<reasoning_effort>..</reasoning_effort>]
        <system_prompt><![CDATA[full text]]></system_prompt></sub_agent>
      ...</sub_agents></list_sub_agent>
    Empty:
      <list_sub_agent><profile>P</profile><empty/></list_sub_agent>

  String fields may be empty; optional numeric tags may be ABSENT (means
  'inherits profile default') — absent tags render NO cells. api_key /
  base_url NEVER appear on the wire and are never parsed or rendered here
  (defense in depth: even an injected tag is ignored).

  Header (always visible, via ToolCardHeader):
    `list_sub_agent ✓` — primary "N subagents", right-meta "profile <name>"
    `list_sub_agent ✓ (empty)` — primary "No subagents", right-meta
      "profile <name>"

  Expanded body (click header to toggle): per-row name (bold) +
  model/url_style muted meta + tuning grid (only tags present in the
  envelope) + FULL system_prompt in a per-row <details> block
  (scrollable, NOT truncated).
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { tryUnwrapToolOutput } from '../../helpers/unwrapToolOutput'

// Minimal shape we need from the parent. ChatView.vue defines a LOCAL `Message` interface
// (different from `api.Message`) so we declare just the fields we read — this keeps the component
// decoupled from whichever Message type the parent uses.
interface ToolMessageLike {
  id?: string
  role?: string
  content: string
  tool_name?: string
}

/** One parsed <sub_agent> row. `has*` flags record tag PRESENCE so the
 *  tuning grid renders only tags present in the envelope (absent =
 *  'inherits profile default', no empty cells). api_key / base_url are
 *  deliberately absent — never parsed, never rendered. */
interface SubAgentRow {
  name: string
  model: string
  urlStyle: string
  thinking: string
  hasThinking: boolean
  temperature: string
  hasTemperature: boolean
  maxCapacityTokens: string | null
  compactionThresholdPercent: string | null
  thinkingBudgetTokens: string | null
  reasoningEffort: string | null
  systemPrompt: string
}

interface ParsedListSubAgent {
  /** True when no `<error>` tag is present. */
  success: boolean
  /** True when the backend returned `<empty/>` (or no rows parsed). */
  isEmpty: boolean
  /** Profile name, or 'unknown' when `<profile>` is absent. */
  profile: string
  rows: SubAgentRow[]
  error: string | null
}

const props = defineProps<{
  message: ToolMessageLike
}>()

const isExpanded = ref(false)

/**
 * Envelope `<parameters>` for this tool message.
 * `list_sub_agent` takes no input, so this is `{}` on the real wire and
 * <ToolParameters> renders nothing (its hasArgs guard skips '' / '{}').
 * Derived here — NOT threaded as a prop — because this component takes
 * `:message` (whole role=tool message), never `:content`/`:parameters`.
 */
const envelopeParams = computed(
  () => tryUnwrapToolOutput(props.message.content)?.parameters ?? '{}',
)

/**
 * Inner `data` payload for this tool message. The dispatcher passes the
 * raw tool message, whose content is the full JSON envelope; we unwrap
 * one level here so the component is self-contained.
 */
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

/**
 * Unwrap the message content to the inner `data` record. Accepts the full
 * JSON envelope string (normal wire shape) or a bare data-object JSON
 * string (defensive fallback for direct callers). Returns null when the
 * content is not parseable JSON at all.
 */
function innerDataOf(
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
      const err = strOrNull(record.error)
      return { data: record, error: err }
    }
    return null
  } catch {
    return null
  }
}

const innerData = computed(
  (): Record<string, unknown> => innerDataOf(props.message.content)?.data ?? {},
)
const innerError = computed((): string | null => {
  const u = innerDataOf(props.message.content)
  if (u === null) return 'tool failed'
  return u.error
})

function parseRow(item: unknown): SubAgentRow {
  const r = asRecord(item)
  const maxCap = strOrNull(r.max_capacity_tokens)
  const compactPct = strOrNull(r.compaction_threshold_percent)
  const budget = strOrNull(r.thinking_budget_tokens)
  const effort = strOrNull(r.reasoning_effort)
  const thinking = strOrNull(r.thinking)
  const temperature = strOrNull(r.temperature)
  return {
    name: typeof r.name === 'string' ? r.name : '',
    model: typeof r.model === 'string' ? r.model : '',
    urlStyle: typeof r.url_style === 'string' ? r.url_style : '',
    thinking: thinking ?? '',
    hasThinking: thinking !== null,
    temperature: temperature ?? '',
    hasTemperature: temperature !== null,
    maxCapacityTokens: maxCap,
    compactionThresholdPercent: compactPct,
    thinkingBudgetTokens: budget,
    reasoningEffort: effort,
    systemPrompt: typeof r.system_prompt === 'string' ? r.system_prompt : '',
  }
}

const parsed = computed((): ParsedListSubAgent => {
  const inner = innerData.value
  const error = innerError.value ?? strOrNull(inner.error)
  if (error !== null) {
    return {
      success: false,
      isEmpty: false,
      profile: strOrNull(inner.profile) ?? 'unknown',
      rows: [],
      error,
    }
  }
  const profile = strOrNull(inner.profile) ?? 'unknown'
  const rows: SubAgentRow[] = []
  const raw = inner.sub_agents
  if (Array.isArray(raw)) {
    for (const item of raw) {
      const row = parseRow(item)
      if (row.name) rows.push(row)
    }
  }
  if (rows.length === 0) {
    return { success: true, isEmpty: true, profile, rows: [], error: null }
  }
  return { success: true, isEmpty: false, profile, rows, error: null }
})

const primaryLabel = computed((): string => {
  if (!parsed.value.success) return 'error'
  if (parsed.value.isEmpty) return 'No subagents'
  const n = parsed.value.rows.length
  return `${n} ${n === 1 ? 'subagent' : 'subagents'}`
})

const rightMeta = computed((): string => {
  if (!parsed.value.success) return parsed.value.error ?? 'error'
  return `profile ${parsed.value.profile}`
})

const expandable = computed(() => true)

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !parsed.success }"
    data-testid="list-sub-agent"
  >
    <ToolCardHeader
      tool-name="list_sub_agent"
      :primary="primaryLabel"
      :primary-title="primaryLabel"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="expandable"
      :right-meta="rightMeta"
      :show-copy="false"
      :show-open-in-editor="false"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
      data-testid="list-sub-agent-body"
    >
      <!-- Error body — always visible when expanded AND error. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="list-sub-agent-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Empty result (valid response, no subagents on this profile). -->
      <div
        v-else-if="parsed.isEmpty"
        class="px-3 py-3 text-center text-[var(--semantic-text-muted)] text-dense"
        data-testid="list-sub-agent-empty"
      >
        No subagents on profile {{ parsed.profile }}.
      </div>

      <!-- Populated rows. -->
      <div v-else class="px-3 py-2 space-y-2">
        <div
          v-for="(row, idx) in parsed.rows"
          :key="idx"
          class="rounded border border-[var(--color-border)] px-2 py-1.5"
          :data-testid="`list-sub-agent-row-${idx}`"
        >
          <!-- Name (bold) + model/url_style muted meta. -->
          <div class="flex items-baseline gap-2 min-w-0">
            <span class="font-semibold text-[var(--semantic-text)] truncate">{{ row.name }}</span>
            <span class="text-[var(--semantic-text-muted)] truncate"
              >{{ row.model }} · {{ row.urlStyle }}</span
            >
          </div>
          <!-- Tuning grid — ONLY tags present in the envelope. -->
          <div class="mt-1 grid grid-cols-2 gap-x-3 gap-y-0.5 text-[var(--semantic-text-muted)]">
            <span v-if="row.hasThinking">thinking: {{ row.thinking }}</span>
            <span v-if="row.hasTemperature">temperature: {{ row.temperature }}</span>
            <span v-if="row.maxCapacityTokens !== null" data-tuning="max_capacity_tokens"
              >max_capacity_tokens: {{ row.maxCapacityTokens }}</span
            >
            <span
              v-if="row.compactionThresholdPercent !== null"
              data-tuning="compaction_threshold_percent"
              >compaction_threshold_percent: {{ row.compactionThresholdPercent }}</span
            >
            <span v-if="row.thinkingBudgetTokens !== null" data-tuning="thinking_budget_tokens"
              >thinking_budget_tokens: {{ row.thinkingBudgetTokens }}</span
            >
            <span v-if="row.reasoningEffort !== null" data-tuning="reasoning_effort"
              >reasoning_effort: {{ row.reasoningEffort }}</span
            >
          </div>
          <!-- FULL system_prompt in an expandable collapsible block. -->
          <details class="mt-1" :data-testid="`list-sub-agent-prompt-${idx}`">
            <summary class="cursor-pointer text-[var(--color-violet)]">system_prompt</summary>
            <pre
              class="mt-1 max-h-64 overflow-auto whitespace-pre-wrap break-words text-[var(--semantic-text)]"
              :data-testid="`list-sub-agent-prompt-body-${idx}`"
              >{{ row.systemPrompt }}</pre>
          </details>
        </div>
      </div>
      <!--
        Envelope params: collapsed <details>, rendered only
        when non-empty (ToolParameters v-ifs on hasArgs). Today this
        is always '{}' for list_sub_agent (no-input tool) so nothing shows.
      -->
      <ToolParameters :parameters="envelopeParams" />
    </div>
  </div>
</template>

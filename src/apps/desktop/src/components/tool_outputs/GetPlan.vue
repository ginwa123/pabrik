<!--
  GetPlan — tool output component for the `get_plan` agent tool.

  Renders the XML envelope produced by `executeGetPlan` in
  `src/modules/agent/tools/get_plan.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Wire shape (the component receives the whole role=tool message, then
  parses the inner `<get_plan>...</get_plan>` envelope from
  `message.content`):
    Present plan:
      <get_plan>
        <plan><![CDATA[
      ## Goal
      ...
      ## Steps
      - [x] Step 1 — done
      - [ ] Step 2 — in progress
        ]]></plan>
      </get_plan>
    No plan set:
      <get_plan><empty/></get_plan>
    Error:
      <get_plan><error>...</error></get_plan>

  Header (always visible, via ToolCardHeader):
    `get_plan ✓`     — right-meta shows item count "N items · N done"
    `get_plan ✓ (empty)` — right-meta shows "no plan set"
    `get_plan ✗ error` (failure) — right-meta shows the error

  Expanded body (click header to toggle):
    Success: the markdown checklist body, with `- [ ]` rendered as an
             unchecked ☐ and `- [x]` rendered as a checked ☑. Plain
             non-checklist lines render as text. The body is shown
             verbatim inside a `<pre>` so the user sees the exact plan
             the agent sees.
    Error:   red error block.
    Empty:   muted "No plan set — use `update_plan` to lay one out" hint.

  The CDATA wrapper around the plan content (set by executeGetPlan.zig)
  is stripped here so we can render the raw markdown line-by-line.

  Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
  Task 8 of 9
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

interface ParsedGetPlan {
  /** True when no `<error>` tag is present and a non-empty plan body exists. */
  success: boolean
  /** True when the backend returned `<empty/>` (no plan set). */
  isEmpty: boolean
  /** Plain-text markdown body (CDATA stripped), or null when absent/error. */
  body: string | null
  /** Error message (populated when `<error>` is present). */
  error: string | null
}

interface ChecklistLine {
  /** "checked" (- [x]), "unchecked" (- [ ]), or "text" (no checkbox prefix). */
  kind: 'checked' | 'unchecked' | 'text'
  /** Display text (with the checkbox prefix stripped for checklist items). */
  text: string
}

const props = defineProps<{
  message: ToolMessageLike
}>()

const isExpanded = ref(true)

/**
 * Envelope `<parameters>` for this tool message (Task 6).
 * `get_plan` takes no input, so this is `{}` on the real wire and
 * <ToolParameters> renders nothing (its hasArgs guard skips '' / '{}').
 * Derived here — NOT threaded as a prop — because this component takes
 * `:message` (whole role=tool message), never `:content`/`:parameters`.
 * Kept (rather than omitted) so any future input args surface with zero
 * template changes. Falls back to '{}' for legacy raw-inner envelopes.
 */
const envelopeParams = computed(() => tryUnwrapToolOutput(props.message.content)?.parameters ?? '{}')

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

/** Unwrap the message content to the inner `data` record. Accepts the full
 * JSON envelope string (normal wire shape) or a bare data-object JSON
 * string (defensive fallback for direct callers). Returns null when the
 * content is not parseable JSON at all. */
function innerDataOf(content: string): { data: Record<string, unknown>; error: string | null } | null {
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

const parsed = computed((): ParsedGetPlan => {
  const unwrapped = innerDataOf(props.message.content)
  const inner = unwrapped?.data ?? {}
  const error = unwrapped === null ? 'tool failed' : unwrapped.error ?? strOrNull(inner.error)
  if (error !== null) {
    return {
      success: false,
      isEmpty: false,
      body: null,
      error,
    }
  }
  // `{empty:true}` is the canonical "no plan" signal.
  if (inner.empty === true) {
    return {
      success: true,
      isEmpty: true,
      body: null,
      error: null,
    }
  }
  // Present branch: `plan` markdown string.
  const body = strOrNull(inner.plan)
  if (body !== null) {
    return {
      success: true,
      isEmpty: false,
      body,
      error: null,
    }
  }
  // Defensive fallback: no recognised shape — treat as empty.
  return {
    success: true,
    isEmpty: true,
    body: null,
    error: null,
  }
})

/** Render the markdown body as a list of checklist / text lines. */
const checklistLines = computed((): ChecklistLine[] => {
  if (!parsed.value.body) return []
  const lines = parsed.value.body.split(/\r?\n/)
  const out: ChecklistLine[] = []
  for (const raw of lines) {
    const line = raw.trimEnd()
    const checkedMatch = line.match(/^(\s*)- \[x\]\s+(.*)$/i)
    if (checkedMatch && checkedMatch[2] !== undefined) {
      out.push({ kind: 'checked', text: checkedMatch[2] })
      continue
    }
    const uncheckedMatch = line.match(/^(\s*)- \[ \]\s+(.*)$/)
    if (uncheckedMatch && uncheckedMatch[2] !== undefined) {
      out.push({ kind: 'unchecked', text: uncheckedMatch[2] })
      continue
    }
    out.push({ kind: 'text', text: line })
  }
  return out
})

const totals = computed(() => {
  const all = checklistLines.value
  const checked = all.filter((l) => l.kind === 'checked').length
  const unchecked = all.filter((l) => l.kind === 'unchecked').length
  return { checked, unchecked, total: checked + unchecked }
})

const primaryLabel = computed((): string => {
  if (!parsed.value.success) return 'error'
  if (parsed.value.isEmpty) return '(empty)'
  // Show "N items" as the primary label so the user sees the scope
  // of the plan at a glance without expanding.
  const t = totals.value
  if (t.total === 0) return '(no checklist)'
  return `${t.total} ${t.total === 1 ? 'item' : 'items'}`
})

const rightMeta = computed((): string => {
  if (!parsed.value.success) return parsed.value.error ?? 'error'
  if (parsed.value.isEmpty) return 'no plan set'
  const t = totals.value
  if (t.total === 0) return ''
  return `${t.checked}/${t.total} done`
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
    data-testid="get-plan"
  >
    <ToolCardHeader
      tool-name="get_plan"
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
      data-testid="get-plan-body"
    >
      <!-- Error body — always visible when expanded AND error. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="get-plan-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Empty result (valid response, no plan yet). -->
      <div
        v-else-if="parsed.isEmpty"
        class="px-3 py-3 text-center text-[var(--semantic-text-muted)] text-dense"
        data-testid="get-plan-empty"
      >
        No plan set — use <code class="text-[var(--color-violet)]">update_plan</code> to lay one out.
      </div>

      <!-- Plan body rendered as a checklist. -->
      <div
        v-else
        class="px-3 py-2 space-y-0.5"
        data-testid="get-plan-checklist"
      >
        <div
          v-for="(line, idx) in checklistLines"
          :key="idx"
          class="flex items-start gap-2 text-[var(--semantic-text)]"
          :data-testid="`get-plan-line-${idx}`"
          :data-kind="line.kind"
        >
          <!-- Checkbox glyph for checklist items. Use literal
               � / ☑ to avoid the CSS-reset surprises of native
               <input type="checkbox"> in a chat bubble (which the
               browser renders full-size by default). -->
          <span
            v-if="line.kind === 'checked'"
            class="shrink-0 text-green-500 w-4 text-center"
            aria-hidden="true"
          >☑</span>
          <span
            v-else-if="line.kind === 'unchecked'"
            class="shrink-0 text-[var(--semantic-text-muted)] w-4 text-center"
            aria-hidden="true"
          >☐</span>
          <span
            v-else
            class="shrink-0 w-4"
            aria-hidden="true"
          ></span>
          <span
            class="whitespace-pre-wrap break-words flex-1 min-w-0"
            :class="line.kind === 'checked' ? 'line-through text-[var(--semantic-text-muted)]' : ''"
          >{{ line.text }}</span>
        </div>
        <!-- Edge case: body present but no checklist lines at all. -->
        <div
          v-if="checklistLines.length === 0"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic"
          data-testid="get-plan-no-checklist"
        >
          (plan body has no checklist lines)
        </div>
      </div>
      <!--
        Envelope params (Task 6): collapsed <details>, rendered only
        when non-empty (ToolParameters v-ifs on hasArgs). Today this
        is always '{}' for get_plan (no-input tool) so nothing shows.
      -->
      <ToolParameters :parameters="envelopeParams" />
    </div>
  </div>
</template>

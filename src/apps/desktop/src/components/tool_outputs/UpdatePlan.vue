<!--
  UpdatePlan — tool output component for the `update_plan` agent tool.

  Renders the XML envelope produced by `executeUpdatePlan` in
  `src/modules/agent/tools/update_plan.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Wire shape (the component receives the whole role=tool message, then
  parses the inner `<update_plan>...</update_plan>` envelope from
  `message.content`):
    Success (UPSERT):
      <update_plan>
        <session_id>s_xxx</session_id>
        <updated_at>YYYY-MM-DD HH:MM:SS</updated_at>
        <plan><![CDATA[
          ...markdown body...
        ]]></plan>
      </update_plan>
    Error:
      <update_plan><error>...</error></update_plan>

  The `<plan>` block carries the just-written content (CDATA-wrapped,
  byte-for-byte) — this is the SAME body the LLM sees back, and the
  source the frontend renders. Mirrors `get_plan`'s
  `<plan><![CDATA[...]]></plan>` shape so the two components share
  the same envelope parser (no separate `parameters` prop needed).

  Header (always visible, via ToolCardHeader):
    `update_plan ✓` (success)            — right-meta shows byte count
    `update_plan ✗ error` (failure)      — right-meta shows the error

  Expanded body (click header to toggle):
    Success: short metadata strip (session_id + updated_at) + the
             checklist body rendered as HTML checkboxes (- [x] / - [ ]).
    Error:   red error block with the full error message.

  Style mirrors SaveMemory.vue (same violet tool-name, ✓/✗ badge,
  rounded-md card frame) but uses ToolCardHeader.vue for the chrome
  to stay aligned with the rest of the tool_outputs family.

  Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
  Task 8 of 9
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
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

interface ParsedUpdatePlan {
  success: boolean
  sessionId: string | null
  updatedAt: string | null
  error: string | null
  /** Plain-text markdown body (CDATA-stripped), or null when absent / error. */
  body: string | null
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

/**
 * Unwrap the message content to the inner `data` record. Accepts the full
 * JSON envelope string (normal wire shape) or a bare data-object JSON
 * string (defensive fallback for direct callers). Returns null when the
 * content is not parseable JSON at all.
 */
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

const parsed = computed((): ParsedUpdatePlan => {
  const unwrapped = innerDataOf(props.message.content)
  const inner = unwrapped?.data ?? {}
  const error = unwrapped === null ? 'tool failed' : unwrapped.error ?? strOrNull(inner.error)
  if (error !== null) {
    return {
      success: false,
      sessionId: null,
      updatedAt: null,
      error,
      body: null,
    }
  }
  return {
    success: true,
    sessionId: strOrNull(inner.session_id),
    updatedAt: strOrNull(inner.updated_at),
    error: null,
    body: strOrNull(inner.plan),
  }
})

/** Render the body as a list of checklist / text lines. */
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

const hasChecklist = computed(() => checklistLines.value.length > 0)

const primaryLabel = computed((): string => {
  if (!parsed.value.success) return 'error'
  return parsed.value.sessionId ?? 'unknown session'
})

const rightMeta = computed((): string => {
  if (!parsed.value.success) return parsed.value.error ?? 'error'
  // Approximate the "wrote N bytes" feel — we don't have the raw input here, so show the timestamp
  // instead. The collapsed bubble uses a byte count, but inside the card the timestamp is more
  // useful for "when did the agent last tick a step?".
  return parsed.value.updatedAt ?? ''
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
    data-testid="update-plan"
  >
    <ToolCardHeader
      tool-name="update_plan"
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
      data-testid="update-plan-body"
    >
      <!-- Error body — always visible when expanded AND error. -->
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-red-500 text-dense"
        data-testid="update-plan-error"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>

      <!-- Success path: metadata strip + plan checklist. -->
      <template v-if="parsed.success">
        <div
          v-if="parsed.sessionId"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="update-plan-session-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Session:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            parsed.sessionId
          }}</span>
        </div>
        <div
          v-if="parsed.updatedAt"
          class="flex gap-2 px-2 py-1.5 text-dense border-b border-dashed border-[var(--color-border)]"
          data-testid="update-plan-updated-row"
        >
          <span class="font-semibold shrink-0 text-[var(--semantic-text-muted)]">Updated:</span>
          <span class="whitespace-pre-wrap break-all text-[var(--semantic-text)]">{{
            parsed.updatedAt
          }}</span>
        </div>

        <!-- Plan body rendered as a checklist. Mirrors GetPlan.vue::template
             so users see what the plan looks like now, without calling
             get_plan separately. The body comes from the <plan><![CDATA[...]]></plan>
             block of the response envelope (NOT from the tool's input args). -->
        <div v-if="hasChecklist" class="px-3 py-2 space-y-0.5" data-testid="update-plan-checklist">
          <div
            v-for="(line, idx) in checklistLines"
            :key="idx"
            class="flex items-start gap-2 text-[var(--semantic-text)]"
            :data-testid="`update-plan-line-${idx}`"
            :data-kind="line.kind"
          >
            <span
              v-if="line.kind === 'checked'"
              class="shrink-0 text-green-500 w-4 text-center"
              aria-hidden="true"
              >☑</span
            >
            <span
              v-else-if="line.kind === 'unchecked'"
              class="shrink-0 text-[var(--semantic-text-muted)] w-4 text-center"
              aria-hidden="true"
              >☐</span
            >
            <span v-else class="shrink-0 w-4" aria-hidden="true"></span>
            <span
              class="whitespace-pre-wrap break-words flex-1 min-w-0"
              :class="
                line.kind === 'checked' ? 'line-through text-[var(--semantic-text-muted)]' : ''
              "
              >{{ line.text }}</span
            >
          </div>
        </div>

        <!-- Hint when no fields (empty envelope edge case). -->
        <div
          v-if="!parsed.sessionId && !parsed.updatedAt && !hasChecklist"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic"
          data-testid="update-plan-empty"
        >
          (no fields in envelope)
        </div>
      </template>
      <!--
        NOTE (Task 6): no <ToolParameters> block here — deliberate.
        `update_plan`'s only input arg is `content` (the markdown body),
        and the backend echoes that SAME body back inside
        `<plan><![CDATA[...]]></plan>`, which this card already renders
        as the checklist above. Surfacing the raw envelope
        `<parameters>{ "content": "..." }</parameters>` would duplicate
        the checklist without adding signal, so the envelope params are
        intentionally not surfaced (see UpdatePlan.spec.ts "real ChatView
        dispatcher path" section: parameters = ignored, <plan> CDATA =
        source of truth). Prop shape stays `:message` (no `:parameters`).
      -->
    </div>
  </div>
</template>

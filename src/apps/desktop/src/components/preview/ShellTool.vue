<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from '../tool_outputs/_shared/ToolParameters.vue'
import { normalizeToolContent, parseShell } from '../tool_outputs/_shared/toolOutputParser'

/**
 * ShellTool — the canonical renderer for shell-tool outputs.
 *
 * Replaces the bash-only `Bash.vue` with a parameterised component. The
 * tool name ('bash' | 'pwsh' | 'command' | future shells) is passed in
 * as a prop and rendered as the violet pill in the card (pill renders the
 * raw prop verbatim, so toolName 'command' shows `command`). The XML
 * envelope is identical across shells (per D2 + D10 in the
 * 2026-08-14-pwsh-tool plan; the unified `command` tool reuses the same
 * 8-tag envelope), so `parseShell(toolName, content)` dispatches to the
 * right parser based on the tool name.
 *
 * Wire schema parity is locked via two tests:
 *   1. backend (Zig): shell_test.zig asserts `@typeName(ShellInput) ==
 *      @typeName(BashInput) == @typeName(PwshInput)`.
 *   2. frontend (TS): toolOutputParser.spec.ts asserts
 *      `parsePwsh(envelope) === parseBash(envelope)`.
 */
const props = defineProps<{
  content: unknown
  toolName: string
  expanded?: boolean
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => parseShell(props.toolName, normalized.value.data))

const stdout = computed(() => parsed.value.stdout)
const stderr = computed(() => parsed.value.stderr)
const exitCode = computed(() => parsed.value.exitCode)
const isTruncated = computed(() => parsed.value.truncated)
const isTimeout = computed(() => parsed.value.timedOut)
const stdoutLines = computed(() => parsed.value.stdoutLines)
const stderrLines = computed(() => parsed.value.stderrLines)

// Command from the `parameters` prop (tool-call args, not the result
// envelope). `parameters` is XML like `<command>sleep 10</command>...`
// from jsonArgsToXml — NOT JSON — but try JSON first for forward-compat.
const parsedParamsCommand = computed((): string | null => {
  const raw = props.parameters
  if (!raw || raw.trim() === '') return null
  try {
    const obj = JSON.parse(raw)
    if (obj && typeof obj === 'object' && typeof (obj as Record<string, unknown>).command === 'string') {
      const cmd = ((obj as Record<string, unknown>).command as string).trim()
      if (cmd !== '') return (obj as Record<string, unknown>).command as string
    }
  } catch {
    // Not JSON — fall through to XML extraction below.
  }
  const m = /<command>([\s\S]*?)<\/command>/.exec(raw)
  if (m) {
    const raw_cmd = m[1] ?? '';
    if (raw_cmd.trim() !== '') return raw_cmd
  }
  return null
})

// Prefer the envelope's command; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its
// command. Treat empty string as null.
const displayCommand = computed((): string | null => {
  const fromEnvelope = parsed.value.command
  if (fromEnvelope && fromEnvelope.trim() !== '') return fromEnvelope
  return parsedParamsCommand.value
})

// Running: no exit code yet, empty envelope content, but we know the command.
const isEmptyContent = (c: unknown): boolean =>
  c === null ||
  c === undefined ||
  (typeof c === 'string' && c.trim().length === 0) ||
  (typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0)
const isRunning = computed(() => {
  return exitCode.value === null && isEmptyContent(props.content) && displayCommand.value !== null
})

// Has stderr content (not empty and not "No errors.")
const hasStderr = computed(() => {
  return stderr.value && stderr.value.trim() !== '' && stderr.value.trim() !== 'No errors.'
})

// The envelope's error string. EVERY tool result carries one - a failed command, a rejected
// argument, a tool name that does not exist.

// It used to be computed by `normalized` and then read by nobody, so a call that never ran
// (success:false, data:null) rendered as a card with a name, a command and no body at all:
// indistinguishable from a command that ran and printed nothing.

// That is how a dead `bash` call got read as "the shell is flaky".
const envelopeError = computed((): string | null => {
  const err = normalized.value.error
  if (typeof err !== 'string') return null
  const trimmed = err.trim()
  return trimmed === '' ? null : trimmed
})
const hasEnvelopeError = computed(() => envelopeError.value !== null)

// Status for styling
const hasWarning = computed(() => isTimeout.value)
const hasError = computed(() => hasEnvelopeError.value || (exitCode.value !== null && exitCode.value !== 0))

const toggle = () => {
  if (!hasWarning.value && !hasError.value && !isTruncated.value) {
    isExpanded.value = !isExpanded.value
  } else {
    isExpanded.value = !isExpanded.value
  }
}

const copyCommand = async (e: Event) => {
  e.stopPropagation()
  if (displayCommand.value) {
    await navigator.clipboard.writeText(displayCommand.value)
  }
}

const copyStdout = async (e: Event) => {
  e.stopPropagation()
  if (stdout.value) {
    await navigator.clipboard.writeText(stdout.value)
  }
}

const copyStderr = async (e: Event) => {
  e.stopPropagation()
  if (stderr.value) {
    await navigator.clipboard.writeText(stderr.value)
  }
}

const copyError = async (e: Event) => {
  e.stopPropagation()
  if (envelopeError.value) {
    await navigator.clipboard.writeText(envelopeError.value)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-orange-500/50 opacity-85': hasWarning && !hasError, 'border-red-500/50 opacity-85': hasError }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      :class="{ 'cursor-default': !hasStderr && !isTruncated }"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <!-- The violet pill shows the tool name. This is the visual marker
           the frontend reads to know "this card is bash" or "this card
           is pwsh" — same component, different label. -->
      <span
        :data-testid="'shell-tool-pill'"
        class="text-[var(--color-violet)] font-semibold text-dense"
        >{{ toolName }}</span
      >
      <span class="flex-1 truncate text-left text-[var(--semantic-text-dim)]" :title="displayCommand || ''">
        $ {{ displayCommand || 'unknown' }}
      </span>
      <span v-if="isRunning" data-testid="shell-tool-running" class="text-micro text-yellow-500 animate-pulse">running…</span>

      <!-- Exit code badge -->
      <span
        v-if="exitCode !== null"
        :data-testid="'shell-tool-exit-code'"
        class="text-micro font-medium"
        :class="exitCode === 0 ? 'text-green-500' : 'text-red-500'"
      >
        {{ exitCode }}
      </span>

      <!-- Truncated badge -->
      <span v-if="isTruncated" class="text-yellow-500 text-micro">
        truncated
      </span>

      <!-- Timeout badge -->
      <span v-if="isTimeout" class="text-orange-500 text-micro">
        timeout
      </span>

      <!-- Failed badge - a success:false envelope with no exit code to show.
           Without it the card carried no failure signal at all in the header. -->
      <span v-if="hasEnvelopeError" data-testid="shell-tool-failed" class="text-red-500 text-micro">
        failed
      </span>

      <!-- Toggle indicator -->
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-lead transition-opacity"
        @click="copyCommand"
        title="Copy command"
      >
        ⎘
      </button>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

      <!-- Expanded content. A failed envelope forces this open: the card's
           whole body IS the error, so leaving it collapsed behind a "+" is
           what made the failure read as "nothing happened". -->
      <div v-if="isExpanded || hasEnvelopeError" class="border-t border-[var(--color-border)]">
        <!-- Envelope error - shown for ANY success:false result, including a
             tool that never ran at all. -->
        <div v-if="hasEnvelopeError" data-testid="shell-tool-error" class="group relative border-b border-dashed border-[var(--color-border)] last:border-b-0">
          <div class="px-2 py-0.5 text-micro text-red-600 font-medium bg-black/[0.02] flex items-center gap-2">
            <span>error</span>
            <button
              class="ml-auto opacity-0 group-hover:opacity-100 text-[var(--semantic-text-muted)] hover:!text-red-500 cursor-pointer text-dense"
              @click="copyError"
              title="Copy error"
            >
              ⎘
            </button>
          </div>
          <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-violet-500/5">{{ envelopeError }}</pre>
        </div>
        <!-- stdout section -->
        <div v-if="stdout" class="group relative border-b border-dashed border-[var(--color-border)] last:border-b-0">
          <div class="px-2 py-0.5 text-micro text-blue-600 font-medium bg-black/[0.02] flex items-center gap-2">
            <span>stdout</span>
            <span class="text-[var(--semantic-text-muted)]">{{ stdoutLines }}L</span>
            <button
              class="ml-auto opacity-0 group-hover:opacity-100 text-[var(--semantic-text-muted)] hover:!text-blue-500 cursor-pointer text-dense"
              @click="copyStdout"
              title="Copy stdout"
            >
              ⎘
            </button>
          </div>
          <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-violet-500/5">{{ stdout || '(empty)' }}</pre>
        </div>

        <!-- stderr section -->
        <div v-if="hasStderr" class="group relative border-b border-dashed border-[var(--color-border)] last:border-b-0">
          <div class="px-2 py-0.5 text-micro text-red-600 font-medium bg-black/[0.02] flex items-center gap-2">
            <span>stderr</span>
            <span class="text-[var(--semantic-text-muted)]">{{ stderrLines }}L</span>
            <button
              class="ml-auto opacity-0 group-hover:opacity-100 text-[var(--semantic-text-muted)] hover:!text-red-500 cursor-pointer text-dense"
              @click="copyStderr"
              title="Copy stderr"
            >
              ⎘
            </button>
          </div>
          <pre class="p-2 m-0 bg-black/[0.02] whitespace-pre-wrap break-all leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-violet-500/5">{{ stderr }}</pre>
        </div>
        <ToolParameters :parameters="parameters" />
      </div>
  </div>
</template>

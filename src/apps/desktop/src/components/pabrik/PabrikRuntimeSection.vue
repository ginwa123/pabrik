<script setup lang="ts">
/** PabrikRuntimeSection — the Runtime tab in WORKSPACE settings. Retry backoff belongs to the run,
 * so each workspace owns its own value; the user-level General tab no longer offers it. */
import { computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

export interface PabrikRuntimeSettings {
  /** Workflow retry backoff in milliseconds (0–60 000). Mirrors
   * `PabrikConfig.retry_delay_ms`. Default 0 = no delay. */
  retry_delay_ms: number
  /** Deadline in milliseconds for ONE streaming LLM call (1 000–1 800 000).
   * Mirrors `PabrikConfig.llm_read_timeout_ms`. Default 900 000 = 15 minutes. */
  llm_read_timeout_ms: number
  /** Whether the agent may compact its own context through the `compaction`
   * tool. Mirrors `PabrikConfig.agent_auto_compaction`. Absent on disk reads as
   * ON; OFF leaves the token-window threshold and the Compact button working. */
  agent_auto_compaction: boolean
}

const model = defineModel<PabrikRuntimeSettings>({ required: true })

// Mirrors the backend clamp on the workspace write path
// (`workspace_config.zig` ScopedKey.max).
const RETRY_DELAY_MIN = 0
const RETRY_DELAY_MAX = 60_000
const READ_TIMEOUT_MIN = 1_000
const READ_TIMEOUT_MAX = 1_800_000

const retryDelaySeconds = computed<number>({
  get() {
    return Math.round((model.value.retry_delay_ms ?? 0) / 1000)
  },
  set(seconds: number) {
    const clamped = Math.min(RETRY_DELAY_MAX, Math.max(RETRY_DELAY_MIN, Math.round(seconds * 1000)))
    model.value = { ...model.value, retry_delay_ms: clamped }
  },
})

function onRetryDelayInput(event: Event) {
  const target = event.target as HTMLInputElement
  const raw = target.value.trim()
  if (raw === '') {
    model.value = { ...model.value, retry_delay_ms: 0 }
    return
  }
  const seconds = Number.parseInt(raw, 10)
  if (!Number.isFinite(seconds)) return
  // The input is in SECONDS and the stored field in MILLISECONDS, so the
  // computed setter owns the conversion and the clamp.
  retryDelaySeconds.value = seconds
}

// `change` event fires when the user commits a value (blur / Enter), which is the natural commit
// boundary for a number input. Listening for `change` (NOT `input`) means vitest's `setValue()`
// (which fires `change` by default) and the user's manual entry both reach the handler.
function onRetryDelayChange(event: Event) {
  onRetryDelayInput(event)
}

const readTimeoutSeconds = computed<number>({
  get() {
    return Math.round((model.value.llm_read_timeout_ms ?? 900_000) / 1000)
  },
  set(seconds: number) {
    const clamped = Math.min(
      READ_TIMEOUT_MAX,
      Math.max(READ_TIMEOUT_MIN, Math.round(seconds * 1000)),
    )
    model.value = { ...model.value, llm_read_timeout_ms: clamped }
  },
})

function onReadTimeoutChange(event: Event) {
  const target = event.target as HTMLInputElement
  const raw = target.value.trim()
  if (raw === '') {
    model.value = { ...model.value, llm_read_timeout_ms: 900_000 }
    return
  }
  const seconds = Number.parseInt(raw, 10)
  if (!Number.isFinite(seconds)) return
  readTimeoutSeconds.value = seconds
}

function onAutoCompactionToggle(event: Event) {
  const checked = (event.target as HTMLInputElement).checked
  model.value = { ...model.value, agent_auto_compaction: checked }
}
</script>

<template>
  <div class="space-y-6" data-testid="pabrik-runtime-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Runtime</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        How agent runs behave in this workspace.
      </p>
    </div>

    <!-- Agent auto-compaction card -->
    <div
      class="rounded-lg p-5 space-y-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="atom" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">
          Agent compaction
        </h3>
      </div>

      <label class="flex items-start gap-3 cursor-pointer" data-testid="row-agent-auto-compaction">
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            Let the agent compact its own context
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Gives the agent the <code class="text-micro font-mono">compaction</code> tool, so it can
            write a handoff envelope and drop earlier turns when the context gets long. Off = the
            tool is refused. Off does NOT disable the token-window threshold below, and the Compact
            button keeps working either way.
          </div>
        </div>
        <input
          type="checkbox"
          data-testid="toggle-agent-auto-compaction"
          :checked="model.agent_auto_compaction"
          @change="onAutoCompactionToggle($event)"
          class="mt-1 w-4 h-4 shrink-0 cursor-pointer"
          style="accent-color: var(--color-violet)"
        />
      </label>
    </div>

    <!-- Retry card -->
    <div
      class="rounded-lg p-5 space-y-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="stopwatch" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Retry</h3>
      </div>

      <label class="flex items-start gap-3" data-testid="row-retry-delay">
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            Retry delay (seconds)
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Backoff before each failed LLM call is retried in this workspace.
            <code class="text-micro font-mono">0</code> = retry immediately. Max 60 seconds (clamped
            server-side to 60 000 ms).
          </div>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <input
            type="number"
            min="0"
            max="60"
            step="1"
            inputmode="numeric"
            data-testid="input-retry-delay-seconds"
            :value="retryDelaySeconds"
            @change="onRetryDelayChange($event)"
            class="w-20 h-8 px-2 rounded-md text-body font-mono text-right"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
          />
          <span class="text-dense font-mono" style="color: var(--semantic-text-muted)">sec</span>
        </div>
      </label>

      <!-- ms readout — shows the underlying value the backend will write -->
      <div
        class="flex items-center justify-end gap-1 text-micro font-mono"
        style="color: var(--semantic-text-dim)"
      >
        <span data-testid="retry-delay-ms-readout"> {{ model.retry_delay_ms }} ms </span>
      </div>
    </div>

    <!-- Streaming timeout card -->
    <div
      class="rounded-lg p-5 space-y-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="stopwatch" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">
          Streaming timeout
        </h3>
      </div>

      <label class="flex items-start gap-3" data-testid="row-read-timeout">
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            One model call may take (seconds)
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Hard deadline for a single streaming LLM call, response head to last chunk. A design or
            wireframe turn sends a 100k-token prompt and asks for a 20 kB file, so it needs more
            than a chat turn. Max 1800 seconds (clamped server-side to 1 800 000 ms).
          </div>
        </div>
        <div class="flex items-center gap-2 shrink-0">
          <input
            type="number"
            min="1"
            max="1800"
            step="1"
            inputmode="numeric"
            data-testid="input-read-timeout-seconds"
            :value="readTimeoutSeconds"
            @change="onReadTimeoutChange($event)"
            class="w-20 h-8 px-2 rounded-md text-body font-mono text-right"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
          />
          <span class="text-dense font-mono" style="color: var(--semantic-text-muted)">sec</span>
        </div>
      </label>

      <div
        class="flex items-center justify-end gap-1 text-micro font-mono"
        style="color: var(--semantic-text-dim)"
      >
        <span data-testid="read-timeout-ms-readout"> {{ model.llm_read_timeout_ms }} ms </span>
      </div>
    </div>
  </div>
</template>

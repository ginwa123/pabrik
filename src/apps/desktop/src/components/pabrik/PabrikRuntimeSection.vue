<script setup lang="ts">
/** PabrikRuntimeSection — the Runtime tab in WORKSPACE settings. Retry backoff belongs to the run,
 * so each workspace owns its own value; the user-level General tab no longer offers it. */
import { computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

export interface PabrikRuntimeSettings {
  /** Workflow retry backoff in milliseconds (0–60 000). Mirrors
   * `PabrikConfig.retry_delay_ms`. Default 0 = no delay. */
  retry_delay_ms: number
}

const model = defineModel<PabrikRuntimeSettings>({ required: true })

// Mirrors the backend clamp on the workspace write path
// (`workspace_config.zig` ScopedKey.max).
const RETRY_DELAY_MIN = 0
const RETRY_DELAY_MAX = 60_000

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
</script>

<template>
  <div class="space-y-6" data-testid="pabrik-runtime-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Runtime</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        How agent runs behave in this workspace.
      </p>
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
  </div>
</template>

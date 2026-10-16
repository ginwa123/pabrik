<script setup lang="ts">
/** PabrikGeneralSection — General tab in Pabrik settings. Three operational settings the user can
 * toggle from the UI: 1. `notify_on_complete` — OS notification when an LLM response finishes with
 * `finish_reason === 'stop'`. Existing config.json field. 2. */
import { computed } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

export interface PabrikGeneralSettings {
  /** OS notification on `finish_reason === 'stop'`. Mirrors
   * `PabrikConfig.notify_on_complete`. Default false. */
  notify_on_complete: boolean
  /** OS notification on transport error / TooManyRetries / outer catch.
   * Mirrors `PabrikConfig.notify_on_error`. Default false. */
  notify_on_error: boolean
  /** Workflow retry backoff in milliseconds (0–60 000). Mirrors
   * `PabrikConfig.retry_delay_ms`. Default 0 = no delay. */
  retry_delay_ms: number
  /** Serve this same UI in the system browser on a random local port.
   * Mirrors `PabrikConfig.web_launch_enabled`. Default false. */
  web_launch_enabled: boolean
}

const model = defineModel<PabrikGeneralSettings>({ required: true })

/** Live browser URL for the web-launch pill. Null = not running /
 * unknown (pill shows a waiting hint instead of Open/Copy targets). */
withDefaults(defineProps<{ webUrl?: string | null }>(), { webUrl: null })

const emit = defineEmits<{
  'open-web': []
  'copy-web': []
}>()

// Hard cap mirrors the backend's PUT clamp
// (pabrik_config_put.zig:133-135). The user typing past this would
// silently snap to 60 000 server-side, so clamp in the UI too.
const RETRY_DELAY_MIN = 0
const RETRY_DELAY_MAX = 60_000

const retryDelaySeconds = computed<number>({
  // Read: convert ms → seconds (rounded) for a friendlier display.
  get() {
    return Math.round((model.value.retry_delay_ms ?? 0) / 1000)
  },
  // Write: convert seconds → ms, clamped to [0, 60_000].
  set(seconds: number) {
    const clamped = Math.min(RETRY_DELAY_MAX, Math.max(RETRY_DELAY_MIN, Math.round(seconds * 1000)))
    model.value = { ...model.value, retry_delay_ms: clamped }
  },
})

function onRetryDelayInput(event: Event) {
  const target = event.target as HTMLInputElement
  // Empty input → keep at 0 (matches the default). Non-numeric → ignore.
  const raw = target.value.trim()
  if (raw === '') {
    model.value = { ...model.value, retry_delay_ms: 0 }
    return
  }
  const seconds = Number.parseInt(raw, 10)
  if (!Number.isFinite(seconds)) return
  // The input shows SECONDS (user-friendly unit); the stored field is
  // MILLISECONDS (matches the backend wire format). Multiply here so
  // "5" in the UI → 5000 ms in the config (5-second delay).
  const ms = Math.min(RETRY_DELAY_MAX, Math.max(RETRY_DELAY_MIN, Math.round(seconds * 1000)))
  model.value = { ...model.value, retry_delay_ms: ms }
}

// `change` event fires when the user commits a value (blur / Enter), which is the natural commit
// boundary for a number input. Listening for `change` (NOT `input`) means vitest's `setValue()`
// (which fires `change` by default) and the user's manual entry both reach the handler.
function onRetryDelayChange(event: Event) {
  onRetryDelayInput(event)
}
</script>

<template>
  <div class="space-y-6" data-testid="pabrik-general-section">
    <!-- Section header — short, human-readable summary of what this tab controls -->
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text);">General</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted);">
        Operational settings — desktop notifications and retry behavior.
      </p>
    </div>

    <!-- Notifications card -->
    <div
      class="rounded-lg p-5 space-y-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="bell" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text);">Notifications</h3>
      </div>

      <!-- Toggle: notify on complete -->
      <label
        class="flex items-start gap-3 cursor-pointer"
        data-testid="row-notify-on-complete"
      >
        <input
          type="checkbox"
          data-testid="toggle-notify-on-complete"
          :checked="model.notify_on_complete"
          @change="model = { ...model, notify_on_complete: ($event.target as HTMLInputElement).checked }"
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet);"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text);">
            Notify when agent finishes
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted);">
            Fire a desktop notification when the LLM response completes
            (<code class="text-micro font-mono">finish_reason = "stop"</code>).
            Useful when you walk away from the app.
          </div>
        </div>
      </label>

      <!-- Toggle: notify on error -->
      <label
        class="flex items-start gap-3 cursor-pointer"
        data-testid="row-notify-on-error"
      >
        <input
          type="checkbox"
          data-testid="toggle-notify-on-error"
          :checked="model.notify_on_error"
          @change="model = { ...model, notify_on_error: ($event.target as HTMLInputElement).checked }"
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet);"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text);">
            Notify when agent fails
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted);">
            Fire a desktop notification when the workflow hits a transport
            error, retries exhaust, or the agentic loop fails. Independent
            from the "finishes" toggle.
          </div>
        </div>
      </label>

      <!-- Toggle: launch web (browser mode) -->
      <label
        class="flex items-start gap-3 cursor-pointer"
        data-testid="row-web-launch"
      >
        <input
          type="checkbox"
          data-testid="toggle-web-launch"
          :checked="model.web_launch_enabled"
          @change="model = { ...model, web_launch_enabled: ($event.target as HTMLInputElement).checked }"
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet);"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text);">
            Launch web (browser mode)
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted);">
            Serve this same UI in your system browser on a random local port.
          </div>
        </div>
      </label>

      <!-- URL pill sub-row — visible only when the toggle is ON -->
      <div
        v-if="model.web_launch_enabled"
        class="flex items-center gap-2 pl-7"
        data-testid="pill-web-url-row"
      >
        <span
          class="flex-1 min-w-0 truncate text-dense font-mono px-2 py-1 rounded-md"
          style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          data-testid="pill-web-url"
        >{{ webUrl ?? 'Starting local web server…' }}</span>
        <button
          type="button"
          data-testid="btn-open-web"
          :disabled="!webUrl"
          class="shrink-0 text-dense font-medium px-2 py-1 rounded-md cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          style="background-color: var(--color-violet); color: white;"
          @click="emit('open-web')"
        >Open</button>
        <button
          type="button"
          data-testid="btn-copy-web"
          :disabled="!webUrl"
          class="shrink-0 text-dense font-medium px-2 py-1 rounded-md cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          @click="emit('copy-web')"
        >Copy</button>
      </div>
    </div>

    <!-- Retry card -->
    <div
      class="rounded-lg p-5 space-y-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="stopwatch" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text);">Retry</h3>
      </div>

      <label
        class="flex items-start gap-3"
        data-testid="row-retry-delay"
      >
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text);">
            Retry delay (seconds)
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted);">
            Backoff before each failed LLM call is retried.
            <code class="text-micro font-mono">0</code> = retry immediately.
            Max 60 seconds (clamped server-side to 60 000 ms).
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
            style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          />
          <span class="text-dense font-mono" style="color: var(--semantic-text-muted);">sec</span>
        </div>
      </label>

      <!-- ms readout — shows the underlying value the backend will write -->
      <div class="flex items-center justify-end gap-1 text-micro font-mono" style="color: var(--semantic-text-dim);">
        <span data-testid="retry-delay-ms-readout">
          {{ model.retry_delay_ms }} ms
        </span>
      </div>
    </div>
  </div>
</template>
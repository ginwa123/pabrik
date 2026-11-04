<script setup lang="ts">
/** PabrikGeneralSection — General tab in USER settings: the settings that apply to every
 * workspace (notifications, web launch, chat view). Retry backoff is per-workspace — see
 * `PabrikRuntimeSection`. */
import UiIcon from '../ui/UiIcon.vue'

export interface PabrikGeneralSettings {
  /** OS notification on `finish_reason === 'stop'`. Mirrors
   * `PabrikConfig.notify_on_complete`. Default false. */
  notify_on_complete: boolean
  /** OS notification on transport error / TooManyRetries / outer catch.
   * Mirrors `PabrikConfig.notify_on_error`. Default false. */
  notify_on_error: boolean
  /** Serve this same UI in the system browser on a random local port.
   * Mirrors `PabrikConfig.web_launch_enabled`. Default false. */
  web_launch_enabled: boolean
  chat_view: 'dev' | 'compact'
}

const CHAT_VIEW_OPTIONS = [
  { value: 'dev', label: 'Dev' },
  { value: 'compact', label: 'Compact' },
] as const

const model = defineModel<PabrikGeneralSettings>({ required: true })

/** Live browser URL for the web-launch pill. Null = not running /
 * unknown (pill shows a waiting hint instead of Open/Copy targets). */
withDefaults(defineProps<{ webUrl?: string | null }>(), { webUrl: null })

const emit = defineEmits<{
  'open-web': []
  'copy-web': []
}>()
</script>

<template>
  <div class="space-y-6" data-testid="pabrik-general-section">
    <!-- Section header — short, human-readable summary of what this tab controls -->
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">General</h2>
      <p class="text-dense mt-1" style="color: var(--semantic-text-muted)">
        Operational settings — desktop notifications and browser launch.
      </p>
    </div>

    <!-- Notifications card -->
    <div
      class="rounded-lg p-5 space-y-4"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="bell" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Notifications</h3>
      </div>

      <!-- Toggle: notify on complete -->
      <label class="flex items-start gap-3 cursor-pointer" data-testid="row-notify-on-complete">
        <input
          type="checkbox"
          data-testid="toggle-notify-on-complete"
          :checked="model.notify_on_complete"
          @change="
            model = { ...model, notify_on_complete: ($event.target as HTMLInputElement).checked }
          "
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet)"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            Notify when agent finishes
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Fire a desktop notification when the LLM response completes (<code
              class="text-micro font-mono"
              >finish_reason = "stop"</code
            >). Useful when you walk away from the app.
          </div>
        </div>
      </label>

      <!-- Toggle: notify on error -->
      <label class="flex items-start gap-3 cursor-pointer" data-testid="row-notify-on-error">
        <input
          type="checkbox"
          data-testid="toggle-notify-on-error"
          :checked="model.notify_on_error"
          @change="
            model = { ...model, notify_on_error: ($event.target as HTMLInputElement).checked }
          "
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet)"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            Notify when agent fails
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Fire a desktop notification when the workflow hits a transport error, retries exhaust,
            or the agentic loop fails. Independent from the "finishes" toggle.
          </div>
        </div>
      </label>

      <!-- Toggle: launch web (browser mode) -->
      <label class="flex items-start gap-3 cursor-pointer" data-testid="row-web-launch">
        <input
          type="checkbox"
          data-testid="toggle-web-launch"
          :checked="model.web_launch_enabled"
          @change="
            model = { ...model, web_launch_enabled: ($event.target as HTMLInputElement).checked }
          "
          class="mt-1 w-4 h-4 cursor-pointer"
          style="accent-color: var(--color-violet)"
        />
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">
            Launch web (browser mode)
          </div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
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
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          data-testid="pill-web-url"
          >{{ webUrl ?? 'Starting local web server…' }}</span
        >
        <button
          type="button"
          data-testid="btn-open-web"
          :disabled="!webUrl"
          class="shrink-0 text-dense font-medium px-2 py-1 rounded-md cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          style="background-color: var(--color-violet); color: white"
          @click="emit('open-web')"
        >
          Open
        </button>
        <button
          type="button"
          data-testid="btn-copy-web"
          :disabled="!webUrl"
          class="shrink-0 text-dense font-medium px-2 py-1 rounded-md cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
          @click="emit('copy-web')"
        >
          Copy
        </button>
      </div>
    </div>

    <!-- Chat view card -->
    <div
      class="rounded-lg p-5 space-y-3"
      style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-2">
        <UiIcon name="cards" size-class="w-4 h-4" />
        <h3 class="text-body font-semibold" style="color: var(--semantic-text)">Chat view</h3>
      </div>

      <div class="flex items-start gap-3" data-testid="row-chat-view">
        <div class="flex-1 min-w-0">
          <div class="text-body font-medium" style="color: var(--semantic-text)">Tool calls</div>
          <div class="text-dense mt-0.5" style="color: var(--semantic-text-muted)">
            Compact folds a run of tool calls into one card. Dev keeps a full card for every call.
          </div>
        </div>
        <div
          class="flex gap-0.5 p-0.5 rounded-lg shrink-0"
          role="radiogroup"
          aria-label="Chat view"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
          "
        >
          <button
            v-for="option in CHAT_VIEW_OPTIONS"
            :key="option.value"
            type="button"
            role="radio"
            :aria-checked="model.chat_view === option.value"
            :data-testid="`chat-view-${option.value}`"
            class="px-3 py-1 rounded-md text-dense font-medium transition-all duration-200"
            :style="
              model.chat_view === option.value
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="model = { ...model, chat_view: option.value }"
          >
            {{ option.label }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

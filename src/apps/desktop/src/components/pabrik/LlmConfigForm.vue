<script setup lang="ts">
import { computed, ref } from 'vue'

export interface LlmConfig {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  /** Which TRANSPORT runs this profile's calls: `"http"` (default) or
   * `"claude-code"` (the local `claude` CLI, subscription auth via
   * `claude login`). Orthogonal to `url_style`, which describes the HTTP
   * wire format only.
   *
   * Optional on purpose: an absent key IS the documented `"http"` default,
   * so a profile authored before this field existed (or one that only
   * fills the HTTP fields) needs no change. */
  backend?: string
  /** Claude Code only: `CLAUDE_CONFIG_DIR`. Lets two profiles keep two
   * different `claude login` sessions side by side — the way per-profile
   * identity works when there is no API key. `null` = CLI default. */
  config_dir?: string | null
  /** Claude Code only: agentic turn ceiling (`--max-turns`).
   * `null` = the CLI's own default. */
  max_turns?: number | null
  /** Optional per-profile override for the context window (in tokens).
   * `null` = no per-profile override (fall through to top-level defaults
   * → built-in). Added in plan 2026-07-07-compaction-inline. */
  max_capacity_tokens: number | null
  /** Optional per-profile compaction threshold as a percentage (0-100).
   * `null` = no per-profile override (fall through to top-level defaults
   * → built-in 80). Added in plan 2026-07-07-compaction-inline. */
  compaction_threshold_percent: number | null
  /** Anthropic-only override for `thinking.budget_tokens`. Range
   * (0, 2_000_000]. `null` = use the 50%-of-max_tokens heuristic
   * (or Anthropic `type: "adaptive"` when `thinking === "auto"`).
   * Hidden when `thinking === "off"`. Plan 2026-08-23-model-thinking. */
  thinking_budget_tokens: number | null
  /** OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
   * `"low" | "medium" | "high" | "auto" | null`. `null` = omit from
   * the request body (model-default reasoning). Anthropic-style
   * URLs ignore this field. Plan 2026-08-23-model-thinking. */
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}

const props = defineProps<{
  modelValue: LlmConfig
  errors?: Partial<Record<keyof LlmConfig, string>>
}>()

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfig]
}>()

const showKey = ref(false)

function update<K extends keyof LlmConfig>(key: K, value: LlmConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: value })
}

const inputBase =
  'w-full px-3 h-8 rounded-md border text-body font-sans transition-colors duration-150'
const inputStyle = (hasError?: boolean): Record<string, string> => ({
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: hasError ? 'var(--color-red)' : 'var(--color-border)',
  // WebView2 defaults to a light color-scheme and paints native <select>
  // white even with an explicit background — this per-element hint forces
  // dark control rendering. Global `color-scheme: dark` in style.css is
  // the primary fix; this is defense-in-depth. See task_1788535488395_0.
  colorScheme: 'dark',
})

const labelBase = 'block text-dense font-medium mb-1.5'
const labelStyle = { color: 'var(--semantic-text-muted)' }
const helperStyle = { color: 'var(--semantic-text-dim)' }
const errorStyle = { color: 'var(--color-red)' }

// === Compaction overrides (per-profile) — plan 2026-07-07-compaction-inline ===

const capacityDisplay = computed<string>({
  get: () =>
    props.modelValue.max_capacity_tokens === null
      ? ''
      : String(props.modelValue.max_capacity_tokens),
  set: (raw: string) => {
    const trimmed = raw.trim()
    if (trimmed === '') return
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_tokens', Math.floor(parsed))
  },
})

const thresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v: number) => {
    if (!Number.isFinite(v)) return
    update('compaction_threshold_percent', Math.max(0, Math.min(100, Math.floor(v))))
  },
})

function setCapacityOverride(on: boolean) {
  update('max_capacity_tokens', on ? (props.modelValue.max_capacity_tokens ?? 500000) : null)
}

function setThresholdOverride(on: boolean) {
  update(
    'compaction_threshold_percent',
    on ? (props.modelValue.compaction_threshold_percent ?? 80) : null,
  )
}

// === Temperature freetext (auto or 0–1) ===
// Free-text input with datalist suggestions for the old presets.
// Valid: "auto" (case-insensitive, normalized to "auto") or a finite
// number in [0, 1]. Invalid input shows an inline error and is NOT
// emitted (last valid value is preserved). A local draft ref allows
// intermediate typing states (e.g. clearing the field) without the
// A local draft ref allows intermediate typing states (e.g. clearing the
// field) without the input snapping back to the prop on every keystroke.
// Seeded from the prop at mount (the open guard — the parent mounts this
// form fresh per modal open) and owned by `onTemperatureInput` after that:
// every temperature prop change originates from this form's own `update()`
// emit, which already carries the draft's value, so there is nothing to
// mirror back.
const temperatureDraft = ref(props.modelValue.temperature)

const temperatureError = computed<string | null>(() => {
  const trimmed = temperatureDraft.value.trim()
  if (trimmed.toLowerCase() === 'auto') return null
  if (trimmed === '') return 'Use auto or a number 0–1.'
  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) return 'Use auto or a number 0–1.'
  return null
})

function onTemperatureInput(raw: string) {
  temperatureDraft.value = raw
  if (temperatureError.value !== null) return
  const trimmed = raw.trim()
  const normalized = trimmed.toLowerCase() === 'auto' ? 'auto' : trimmed
  if (normalized !== props.modelValue.temperature) update('temperature', normalized)
}

// === Transport gating — `backend` (orthogonal to `url_style`) ===
// A claude-code profile runs the local `claude` CLI: there is no base URL,
// no API key and no HTTP body shape to choose, so those controls are hidden
// rather than shown-but-ignored. Its own knobs (`config_dir`, `max_turns`)
// appear instead. Hidden fields keep their values (not nulled) so switching
// backends back and forth does not lose what the user typed.
const isClaudeCodeBackend = computed(() => props.modelValue.backend === 'claude-code')
const isHttpBackend = computed(() => !isClaudeCodeBackend.value)

// === Per-style gating — plan 2026-09-01-migrate-openai-legacy-to-response ===
// thinking_budget_tokens is Anthropic-only; reasoning_effort is OpenAI + Responses.
// Hidden fields preserve values (not nulled) so switching styles doesn't lose data.
const isAnthropic = computed(() => props.modelValue.url_style === 'anthropic')
const isOpenAIStyle = computed(
  () => props.modelValue.url_style === 'openai' || props.modelValue.url_style === 'openai-response',
)
</script>

<template>
  <div class="space-y-4">
    <!-- Backend — which TRANSPORT runs this profile. Gates everything below:
         HTTP shows base URL / API key / wire style; Claude Code shows the
         CLI's own knobs. -->
    <div>
      <label :class="labelBase" :style="labelStyle">Backend</label>
      <select
        :value="modelValue.backend"
        @change="update('backend', ($event.target as HTMLSelectElement).value)"
        :class="inputBase"
        :style="inputStyle()"
        data-testid="backend-select"
      >
        <option value="http">HTTP (base URL + API key)</option>
        <option value="claude-code">Claude Code (local CLI)</option>
      </select>
      <p class="text-dense mt-1" :style="helperStyle">
        {{
          isClaudeCodeBackend
            ? 'Runs the local `claude` CLI with your subscription — no API key or Base URL.'
            : 'Calls an HTTP endpoint using the wire format below.'
        }}
      </p>
    </div>

    <!-- Model -->
    <div>
      <label :class="labelBase" :style="labelStyle">
        Model <span style="color: var(--color-red)">*</span>
      </label>
      <input
        :value="modelValue.model"
        @input="update('model', ($event.target as HTMLInputElement).value)"
        type="text"
        :placeholder="isClaudeCodeBackend ? 'sonnet' : 'MiniMax-M2.7'"
        :class="inputBase"
        :style="inputStyle(!!errors?.model)"
        data-testid="model-input"
      />
      <p v-if="errors?.model" class="text-dense mt-1" :style="errorStyle">{{ errors.model }}</p>
    </div>

    <!-- Base URL — HTTP only -->
    <div v-if="isHttpBackend">
      <label :class="labelBase" :style="labelStyle">Base URL</label>
      <input
        :value="modelValue.base_url"
        @input="update('base_url', ($event.target as HTMLInputElement).value)"
        type="text"
        placeholder="https://api.minimax.io/v1"
        :class="inputBase"
        :style="inputStyle(!!errors?.base_url)"
        data-testid="base-url-input"
      />
      <p v-if="errors?.base_url" class="text-dense mt-1" :style="errorStyle">
        {{ errors.base_url }}
      </p>
    </div>

    <!-- Thinking / Temperature / URL style — HTTP only, 3 columns -->
    <div v-if="isHttpBackend" class="grid grid-cols-3 gap-3">
      <div>
        <label :class="labelBase" :style="labelStyle">Thinking</label>
        <select
          :value="modelValue.thinking"
          @change="update('thinking', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="auto">Auto</option>
          <option value="on">On</option>
          <option value="off">Off</option>
        </select>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">Temperature</label>
        <input
          :value="temperatureDraft"
          @input="onTemperatureInput(($event.target as HTMLInputElement).value)"
          type="text"
          inputmode="decimal"
          placeholder="auto or 0–1"
          list="llm-temperature-presets"
          autocomplete="off"
          :class="inputBase"
          :style="inputStyle(!!temperatureError)"
          data-testid="temperature-input"
        />
        <datalist id="llm-temperature-presets">
          <option value="auto" label="Auto" />
          <option value="0" label="0 — Precise" />
          <option value="0.5" />
          <option value="1" label="1 — Balanced" />
        </datalist>
        <p v-if="temperatureError" class="text-dense mt-1" :style="errorStyle">
          {{ temperatureError }}
        </p>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">URL style</label>
        <select
          :value="modelValue.url_style"
          @change="update('url_style', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="url-style-select"
        >
          <option value="openai">OpenAI</option>
          <option value="openai-response">OpenAI Response</option>
          <option value="anthropic">Anthropic</option>
        </select>
      </div>
    </div>

    <!-- Claude Code knobs — CLI only. `config_dir` is what makes two
         profiles two different logins. -->
    <div v-if="isClaudeCodeBackend" class="grid grid-cols-2 gap-3">
      <div>
        <label :class="labelBase" :style="labelStyle">
          Config dir
          <span class="block text-dense mt-0.5" :style="helperStyle">
            CLAUDE_CONFIG_DIR. Blank = ~/.claude. Point two profiles at two dirs to keep two logins
            apart.
          </span>
        </label>
        <input
          :value="modelValue.config_dir ?? ''"
          @input="
            (e) => {
              const raw = (e.target as HTMLInputElement).value
              update('config_dir', raw === '' ? null : raw)
            }
          "
          type="text"
          placeholder="~/.claude-work"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="claude-config-dir-input"
        />
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">
          Max turns
          <span class="block text-dense mt-0.5" :style="helperStyle">
            Agentic turn ceiling (--max-turns). Blank = CLI default.
          </span>
        </label>
        <input
          :value="modelValue.max_turns ?? ''"
          @input="
            (e) => {
              const raw = (e.target as HTMLInputElement).value
              if (raw === '') {
                update('max_turns', null)
              } else {
                const parsed = parseInt(raw, 10)
                update('max_turns', Number.isFinite(parsed) ? Math.max(1, parsed) : null)
              }
            }
          "
          type="number"
          min="1"
          step="1"
          placeholder="40"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="claude-max-turns-input"
        />
      </div>
    </div>

    <!-- Thinking budget + Reasoning effort — plan 2026-08-23-model-thinking.
         Per-style gating (plan 2026-09-01-migrate-openai-legacy-to-response):
           - thinking_budget_tokens: Anthropic only
           - reasoning_effort: OpenAI + OpenAI-Response
         HTTP only: both are request-body knobs the CLI never sees. Hidden
         when thinking === "off" because the budget is irrelevant and the
         effort dropdown is meaningless when extended reasoning is disabled.
         Hidden fields preserve values (not nulled) so switching styles
         doesn't lose data — only visibility changes. -->
    <div v-if="isHttpBackend && modelValue.thinking !== 'off'" class="grid grid-cols-2 gap-3">
      <div v-if="isAnthropic">
        <label :class="labelBase" :style="labelStyle">
          Thinking budget tokens
          <span class="block text-dense mt-0.5" :style="helperStyle">
            Anthropic only. Min 1024. Null = heuristic / adaptive.
          </span>
        </label>
        <input
          :value="modelValue.thinking_budget_tokens ?? ''"
          @input="
            (e) => {
              const raw = (e.target as HTMLInputElement).value
              if (raw === '') {
                update('thinking_budget_tokens', null)
              } else {
                const parsed = parseInt(raw, 10)
                update(
                  'thinking_budget_tokens',
                  Number.isFinite(parsed) ? Math.max(1024, parsed) : null,
                )
              }
            }
          "
          type="number"
          min="1024"
          step="512"
          placeholder="auto"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="thinking-budget-input"
        />
      </div>
      <div v-if="isOpenAIStyle">
        <label :class="labelBase" :style="labelStyle">
          Reasoning effort
          <span class="block text-dense mt-0.5" :style="helperStyle">
            OpenAI / Responses only (o1/o3/GPT-5/DeepSeek-R1).
          </span>
        </label>
        <select
          :value="modelValue.reasoning_effort ?? ''"
          @change="
            (e) => {
              const raw = (e.target as HTMLSelectElement).value
              update(
                'reasoning_effort',
                raw === '' ? null : (raw as 'low' | 'medium' | 'high' | 'auto'),
              )
            }
          "
          :class="inputBase"
          :style="inputStyle()"
          data-testid="reasoning-effort-select"
        >
          <option value="">Auto</option>
          <option value="low">Low</option>
          <option value="medium">Medium</option>
          <option value="high">High</option>
        </select>
      </div>
    </div>

    <!-- API key with show/hide — HTTP only -->
    <div v-if="isHttpBackend">
      <label :class="labelBase" :style="labelStyle">
        API key
        <span v-if="!modelValue.api_key" style="color: var(--color-red)">*</span>
      </label>
      <div class="relative">
        <input
          :value="modelValue.api_key"
          @input="update('api_key', ($event.target as HTMLInputElement).value)"
          :type="showKey ? 'text' : 'password'"
          placeholder="sk-..."
          :class="inputBase + ' pr-9'"
          :style="inputStyle(!!errors?.api_key)"
          data-testid="api-key-input"
        />
        <button
          type="button"
          @click="showKey = !showKey"
          :aria-label="showKey ? 'Hide API key' : 'Show API key'"
          :title="showKey ? 'Hide' : 'Show'"
          data-testid="api-key-toggle"
          class="absolute right-2 top-1/2 -translate-y-1/2 w-6 h-6 flex items-center justify-center text-dense"
          style="color: var(--semantic-text-dim)"
        >
          {{ showKey ? '◉' : '○' }}
        </button>
      </div>
      <p v-if="errors?.api_key" class="text-dense mt-1" :style="errorStyle">{{ errors.api_key }}</p>
    </div>

    <!-- Compaction overrides (per-profile) — plan 2026-07-07-compaction-inline -->
    <div class="border-t pt-4 mt-2" style="border-color: var(--color-border)">
      <h3 class="font-mono text-dense uppercase tracking-wider mb-3" :style="labelStyle">
        ── Compaction overrides ──
      </h3>

      <div class="space-y-3">
        <div>
          <label class="flex items-start gap-2 cursor-pointer text-body">
            <input
              :checked="modelValue.max_capacity_tokens !== null"
              @change="setCapacityOverride(($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet)"
              data-testid="profile-capacity-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the context window</span>
              <span class="block text-dense mt-0.5" :style="helperStyle">
                Falls back to top-level defaults → built-in.
              </span>
            </span>
          </label>
        </div>

        <div :class="{ 'opacity-50 pointer-events-none': modelValue.max_capacity_tokens === null }">
          <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
          <input
            :value="capacityDisplay"
            @input="capacityDisplay = ($event.target as HTMLInputElement).value"
            type="number"
            min="0"
            step="1000"
            placeholder="500000"
            :class="inputBase"
            :style="inputStyle(!!errors?.max_capacity_tokens)"
            :disabled="modelValue.max_capacity_tokens === null"
            data-testid="profile-capacity-input"
          />
        </div>

        <div>
          <label class="flex items-start gap-2 cursor-pointer text-body">
            <input
              :checked="modelValue.compaction_threshold_percent !== null"
              @change="setThresholdOverride(($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet)"
              data-testid="profile-threshold-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the compaction threshold</span>
              <span class="block text-dense mt-0.5" :style="helperStyle">
                Falls back to top-level defaults → built-in 80.
              </span>
            </span>
          </label>
        </div>

        <div
          :class="{
            'opacity-50 pointer-events-none': modelValue.compaction_threshold_percent === null,
          }"
        >
          <div class="flex items-center justify-between mb-1.5">
            <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
            <span class="font-mono text-dense" :style="labelStyle">{{ thresholdDisplay }}</span>
          </div>
          <input
            :value="thresholdDisplay"
            @input="thresholdDisplay = parseFloat(($event.target as HTMLInputElement).value)"
            type="range"
            min="0"
            max="100"
            step="1"
            class="w-full"
            :disabled="modelValue.compaction_threshold_percent === null"
            data-testid="profile-threshold-slider"
          />
        </div>
      </div>
    </div>
  </div>
</template>

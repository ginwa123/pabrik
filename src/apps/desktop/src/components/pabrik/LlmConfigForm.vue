<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'

import {
  getModelCatalog,
  resolveModelOutcome,
  type ModelCatalogEntry,
  type ModelResolve,
} from '../../api'

/**
 * The profile form.
 *
 * THE SHAPE OF THIS FORM IS THE FEATURE. It shows THREE things — the model, one
 * line of facts, the API key — and every other knob lives behind `Advanced` with
 * a placeholder that states its own default (`inherit — openai`).
 *
 * Why: the face of this dialog used to expose 12 controls, and two of them
 * (`max_capacity_tokens`, `compaction_threshold_percent`) decided when a chat
 * throws its history away. Nobody could tell what the numbers were, because the
 * app did not know either — `LLMModels.getModelTokenCount` returned a built-in
 * 200_000 for every model that was not MiniMax. models.dev knows, the backend
 * now stores it, and this form shows the two numbers that actually matter:
 * the context window, and where compaction fires.
 *
 * The fact line is read-only on purpose. It is not a control; it is the answer
 * to "what will this profile do", including WHERE the answer came from
 * (`models.dev` vs `built-in`).
 */

export interface LlmConfig {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  /** Which TRANSPORT runs this profile's calls: `"http"` (default), `"claude-code"` (the local
   * `claude` CLI, subscription auth via `claude login`), or `"opencode"` (the local `opencode` CLI,
   * auth via `opencode login`). */
  /** Orthogonal to `url_style`, which keeps describing the HTTP body shape only. Optional on
   * purpose: an absent key IS the documented `"http"` default, so a profile that predates this
   * field needs no change. */
  backend?: string
  /**    * Claude Code only: `CLAUDE_CONFIG_DIR`. Two profiles pointing at two directories are two
   * different `claude login` sessions — the way per-profile identity works when there is no API
   * key. `null` = the CLI default (`~/.claude`). */
  config_dir?: string | null
  /** Claude Code only: agentic turn ceiling (`--max-turns`).
   * `null` = the CLI's own default. */
  max_turns?: number | null
  /** OpenCode only: which of the CLI's agents runs the turn (`--agent`).
   * `null` = the CLI's default agent. */
  opencode_agent?: string | null
  /** OpenCode only: whether to pass `--auto`. `null`/absent = on (the
   * headless default); `false` = off. */
  opencode_auto?: boolean | null
  /** Optional per-profile override for the context window (in tokens).
   * `null` = resolve from the catalog, then fall through to the built-in. */
  max_capacity_tokens: number | null
  /** Optional per-profile compaction threshold as a percentage (0-100).
   * `null` = the global default (built-in 80). */
  compaction_threshold_percent: number | null
  /**    * Anthropic-only override for `thinking.budget_tokens`. Range (0, 2_000_000]. `null` = the
   * 50%-of-max heuristic, or Anthropic's `type: "adaptive"` when `thinking === "auto"`. */
  thinking_budget_tokens: number | null
  /** OpenAI-style reasoning effort. `null` = omit from the request body
   * (model-default reasoning). Anthropic-style URLs ignore it. */
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}

const props = defineProps<{
  modelValue: LlmConfig
  errors?: Partial<Record<keyof LlmConfig, string>>
  /** Provider id, when a picker row supplied one. Narrows the resolve. */
  modelProvider?: string
}>()

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfig]
}>()

function update<K extends keyof LlmConfig>(key: K, value: LlmConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: value })
}

const inputBase =
  'w-full px-3 h-8 rounded-md border text-body font-sans transition-colors duration-150'
const inputStyle = (hasError?: boolean): Record<string, string> => ({
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: hasError ? 'var(--color-red)' : 'var(--color-border)',
  // WebView2 paints native <select> white without this hint.
  colorScheme: 'dark',
})
const labelBase = 'block text-dense font-medium mb-1.5'
const labelStyle = { color: 'var(--semantic-text-muted)' }
const helperStyle = { color: 'var(--semantic-text-dim)' }
const errorStyle = { color: 'var(--color-red)' }

// === The one call this dialog makes =====================================
// Resolve (model, provider) into facts. Runs on mount, on a debounced input,
// and immediately when a picker row is chosen.

const resolved = ref<ModelResolve | null>(null)
const resolveError = ref<string | null>(null)
const resolving = ref(false)
let debounceTimer: ReturnType<typeof setTimeout> | null = null

async function runResolve(): Promise<void> {
  const model = props.modelValue.model.trim()
  if (model.length < 2) {
    resolved.value = null
    resolveError.value = null
    return
  }
  resolving.value = true
  const outcome = await resolveModelOutcome(model, props.modelProvider)
  resolving.value = false
  if (outcome.kind === 'ok') {
    resolved.value = outcome.value
    resolveError.value = null
  } else {
    // The reason is KEPT and rendered. A fact line that silently showed nothing
    // would leave the user unable to tell "unknown model" from "backend down".
    resolved.value = null
    resolveError.value = outcome.message
  }
}

function scheduleResolve(): void {
  if (debounceTimer !== null) clearTimeout(debounceTimer)
  debounceTimer = setTimeout(() => void runResolve(), 250)
}

onMounted(() => void runResolve())

// === Model picker =======================================================

const pickerOpen = ref(false)
const pickerResults = ref<ModelCatalogEntry[]>([])
const pickerTotal = ref(0)
const catalogState = ref<'fresh' | 'stale' | 'absent'>('absent')
const pickerError = ref<string | null>(null)
let pickerTimer: ReturnType<typeof setTimeout> | null = null

async function runPickerSearch(): Promise<void> {
  try {
    const res = await getModelCatalog(props.modelValue.model.trim() || undefined, undefined, 6)
    pickerResults.value = res.models
    pickerTotal.value = res.total
    catalogState.value = res.catalog
    pickerError.value = null
  } catch (err) {
    // A picker that cannot reach the catalog must not break typing — the field stays free text. But
    // the reason is KEPT and rendered below, because "this model has no matches" and "we could not
    // search" are different answers and must not look the same.
    pickerError.value = err instanceof Error ? err.message : String(err)
    pickerResults.value = []
    pickerTotal.value = 0
  }
}

function onModelInput(raw: string): void {
  update('model', raw)
  pickerOpen.value = true
  if (pickerTimer !== null) clearTimeout(pickerTimer)
  pickerTimer = setTimeout(() => void runPickerSearch(), 200)
  scheduleResolve()
}

function chooseModel(entry: ModelCatalogEntry): void {
  // The model id is what goes on the wire; the provider is remembered so the
  // resolve answers for THAT provider's endpoint.
  emit('update:modelValue', {
    ...props.modelValue,
    model: entry.model_id,
    // An empty base_url means "use the catalog's" — the field stays overrideable.
    // NOT for a CLI backend: those have no endpoint at all, and setting one
    // would trip the profile validator (base_url is rejected for the CLI).
    base_url: isCliBackend.value
      ? props.modelValue.base_url
      : props.modelValue.base_url || entry.provider_name,
  })
  pickerOpen.value = false
  void runResolve()
}

// === The fact line ======================================================

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 1)}M`
  if (n >= 1_000) return `${Math.round(n / 1_000)}k`
  return String(n)
}

/** The effective threshold in tokens: this profile's percentage, or the global 80. */
const effectiveThreshold = computed<number | null>(() => {
  const r = resolved.value
  if (!r) return null
  const pct = props.modelValue.compaction_threshold_percent ?? 80
  return Math.floor((r.context_window * pct) / 100)
})

const factTokens = computed<string[]>(() => {
  const r = resolved.value
  if (!r) return []
  const tokens: string[] = []
  if (r.provider_name) tokens.push(r.provider_name)
  tokens.push(`${fmtTokens(r.context_window)} context`)
  const at = effectiveThreshold.value
  if (at !== null) tokens.push(`compacts at ${fmtTokens(at)}`)
  if (r.cost) tokens.push(`$${r.cost.input}/$${r.cost.output}`)
  tokens.push(r.source === 'catalog' ? 'models.dev' : 'built-in')
  return tokens
})

/** Non-null only when the line is a WARNING rather than a fact. */
const factWarning = computed<string | null>(() => {
  if (resolveError.value) return `could not resolve — ${resolveError.value}`
  const r = resolved.value
  if (!r) {
    if (props.modelValue.model.trim().length < 2) return null
    return 'checking…'
  }
  if (r.source === 'builtin') {
    return r.catalog === 'absent'
      ? 'no catalog yet — the built-in 200k window applies'
      : 'unknown model — the built-in 200k window applies'
  }
  return null
})

// === Transport gating (`backend`, orthogonal to `url_style`) ============= A CLI profile
// (claude-code, opencode) runs a local binary: no base URL, no API key, no HTTP body shape, and no
// request-body knobs.

// Those controls are HIDDEN rather than shown-but-ignored, and the CLI's own knobs appear instead.
// Hidden fields keep their values (never nulled) so flipping backends back and forth does not
// discard what the user typed.
const isClaudeCodeBackend = computed<boolean>(() => props.modelValue.backend === 'claude-code')
const isOpencodeBackend = computed<boolean>(() => props.modelValue.backend === 'opencode')
/** True for any local-CLI backend — the set that hides every HTTP control. */
const isCliBackend = computed<boolean>(() => isClaudeCodeBackend.value || isOpencodeBackend.value)
const isHttpBackend = computed<boolean>(() => !isCliBackend.value)

// === Temperature (free text: "auto" or 0–1) =============================

const temperatureDraft = ref(props.modelValue.temperature)

const temperatureError = computed<string | null>(() => {
  const trimmed = temperatureDraft.value.trim()
  if (trimmed.toLowerCase() === 'auto') return null
  if (trimmed === '') return 'Use auto or a number 0–1.'
  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > 1) return 'Use auto or a number 0–1.'
  return null
})

function onTemperatureInput(raw: string): void {
  temperatureDraft.value = raw
  if (temperatureError.value !== null) return
  const trimmed = raw.trim()
  const normalized = trimmed.toLowerCase() === 'auto' ? 'auto' : trimmed
  if (normalized !== props.modelValue.temperature) update('temperature', normalized)
}

// === Capability gating comes from the MODEL, not the wire shape =========
// The old form showed a Reasoning-effort dropdown for every OpenAI-shaped
// profile, including models that ignore the field entirely.
/** True only when the catalog actually answered for this model. */
const hasFacts = computed<boolean>(() => resolved.value?.source === 'catalog')

/** Does the model support extended reasoning at all? With facts: its own `reasoning_options`.
 * WITHOUT facts — catalog unreachable, unknown model, first run — it degrades to the OLD
 * `url_style`-based gate rather than hiding a control because a request failed. */
/** The user cannot tell "this model has no effort control" from "we could not ask", so we do not
 * pretend to. */
const modelSupportsReasoning = computed<boolean>(() => {
  if (!hasFacts.value) return true
  return resolved.value?.reasoning !== 'none'
})
const effortOptions = computed<string[]>(() => resolved.value?.effort_values_sendable ?? [])
const isAnthropicShape = computed<boolean>(
  () => (resolved.value?.url_style ?? props.modelValue.url_style) === 'anthropic',
)
// Extended reasoning switched off means BOTH controls are meaningless, whatever
// the model supports — the old form's gate, kept.
const reasoningGate = computed<boolean>(() => props.modelValue.thinking !== 'off')
const showsBudget = computed<boolean>(
  () => reasoningGate.value && isAnthropicShape.value && modelSupportsReasoning.value,
)
const showsEffort = computed<boolean>(
  () => reasoningGate.value && !isAnthropicShape.value && modelSupportsReasoning.value,
)

// === Overrides ========================================================== Every numeric override
// is `null` until the user types.

// An empty field is the ONLY spelling of "inherit" — there is no checkbox, and a cleared field
// emits `null`, never `""` (an empty slice binds as SQL NULL server-side).

const advancedOpen = ref(false)
const showKey = ref(false)

const capacityDraft = computed<string>({
  get: () =>
    props.modelValue.max_capacity_tokens === null
      ? ''
      : String(props.modelValue.max_capacity_tokens),
  set: (raw: string) => {
    const trimmed = raw.trim()
    if (trimmed === '') {
      update('max_capacity_tokens', null)
      return
    }
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_tokens', Math.floor(parsed))
  },
})

const thresholdDraft = computed<string>({
  get: () =>
    props.modelValue.compaction_threshold_percent === null
      ? ''
      : String(props.modelValue.compaction_threshold_percent),
  set: (raw: string) => {
    const trimmed = raw.trim()
    if (trimmed === '') {
      update('compaction_threshold_percent', null)
      return
    }
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed)) return
    update('compaction_threshold_percent', Math.max(0, Math.min(100, Math.floor(parsed))))
  },
})

const overrideCount = computed<number>(() => {
  let n = 0
  if (props.modelValue.max_capacity_tokens !== null) n += 1
  if (props.modelValue.compaction_threshold_percent !== null) n += 1
  if (props.modelValue.thinking !== 'auto') n += 1
  if (props.modelValue.temperature !== 'auto') n += 1
  if (props.modelValue.base_url.trim() !== '') n += 1
  if (props.modelValue.thinking_budget_tokens !== null) n += 1
  if (props.modelValue.reasoning_effort !== null) n += 1
  return n
})
</script>

<template>
  <div class="space-y-4">
    <!-- ── Backend: which TRANSPORT runs this profile ────────────────── -->
    <!-- Gates everything below. HTTP shows the connection + request-body
         controls; claude-code shows the CLI's own knobs instead. -->
    <div>
      <label :class="labelBase" :style="labelStyle">Backend</label>
      <select
        :value="modelValue.backend ?? 'http'"
        @change="update('backend', ($event.target as HTMLSelectElement).value)"
        :class="inputBase"
        :style="inputStyle()"
        data-testid="backend-select"
      >
        <option value="http">HTTP (base URL + API key)</option>
        <option value="claude-code">Claude Code (local CLI)</option>
        <option value="opencode">OpenCode (local CLI)</option>
      </select>
      <p class="text-dense mt-1" :style="helperStyle">
        {{
          isClaudeCodeBackend
            ? 'Runs the local claude CLI with your subscription — no API key or Base URL.'
            : isOpencodeBackend
              ? 'Runs the local opencode CLI — no API key or Base URL.'
              : 'Calls an HTTP endpoint using the body shape below.'
        }}
      </p>
    </div>

    <!-- ── Model + the one fact line ─────────────────────────────────── -->
    <div>
      <label :class="labelBase" :style="labelStyle"
        >Model <span style="color: var(--color-red)">*</span></label
      >
      <div class="relative">
        <input
          :value="modelValue.model"
          @input="onModelInput(($event.target as HTMLInputElement).value)"
          @focus="pickerOpen = true"
          @blur="pickerOpen = false"
          type="text"
          placeholder="deepseek-flash"
          autocomplete="off"
          :class="inputBase + ' pr-8'"
          :style="inputStyle(!!errors?.model)"
          data-testid="model-input"
        />
        <span
          class="absolute right-3 top-1/2 -translate-y-1/2 text-dense pointer-events-none"
          style="color: var(--semantic-text-dim)"
          >{{ resolving ? '⋯' : '▾' }}</span
        >
      </div>
      <p v-if="errors?.model" class="text-dense mt-1" :style="errorStyle">{{ errors.model }}</p>

      <!-- Read-only facts. Not a control: the answer to "what will this do". -->
      <p
        v-if="factTokens.length > 0 && !factWarning"
        class="font-mono text-dense mt-1.5"
        data-testid="model-fact-line"
        style="color: var(--color-violet)"
      >
        <template v-for="(t, i) in factTokens" :key="t + i">
          <span v-if="i > 0" style="color: var(--semantic-text-dim)"> · </span>
          <span :style="i === factTokens.length - 1 ? { color: 'var(--semantic-text-dim)' } : {}">{{
            t
          }}</span>
        </template>
      </p>
      <p
        v-else-if="factWarning"
        class="font-mono text-dense mt-1.5"
        data-testid="model-fact-line"
        style="color: var(--color-yellow, #c9a86a)"
      >
        {{ factWarning }}
      </p>

      <!-- Picker: free text stays; this only offers what the catalog knows. -->
      <div
        v-if="pickerOpen && pickerError"
        class="mt-1.5 px-3 py-1.5 rounded-md border font-mono text-dense"
        style="border-color: var(--color-border); color: var(--color-red)"
        data-testid="model-picker-error"
      >
        catalog unavailable — {{ pickerError }}
      </div>
      <div
        v-else-if="pickerOpen && pickerResults.length > 0"
        class="mt-1.5 rounded-md border overflow-hidden"
        style="background-color: var(--semantic-content-bg); border-color: var(--color-border)"
        data-testid="model-picker"
      >
        <div
          class="text-micro font-mono px-3 py-1.5 border-b"
          style="color: var(--semantic-text-dim); border-color: var(--color-border)"
        >
          {{ pickerTotal }} match{{ pickerTotal === 1 ? '' : 'es' }}
        </div>
        <button
          v-for="m in pickerResults"
          :key="m.provider_id + '/' + m.model_id"
          type="button"
          @mousedown.prevent="chooseModel(m)"
          class="w-full flex items-center justify-between gap-3 px-3 py-1.5 hover:opacity-80 text-left"
          :data-testid="`model-option-${m.model_id}`"
        >
          <span class="font-mono text-dense truncate" style="color: var(--semantic-text)">{{
            m.model_id
          }}</span>
          <span class="font-mono text-micro shrink-0" style="color: var(--semantic-text-dim)">
            · {{ m.provider_name
            }}<template v-if="m.context_window"> · {{ fmtTokens(m.context_window) }}</template>
          </span>
        </button>
      </div>
    </div>

    <!-- ── API key (HTTP only) ───────────────────────────────────────── -->
    <div v-if="isHttpBackend">
      <label :class="labelBase" :style="labelStyle"
        >API key <span style="color: var(--color-red)">*</span></label
      >
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

    <!-- ── Advanced: everything else, with its default spelled out ──── -->
    <div class="rounded-md border" style="border-color: var(--color-border)">
      <button
        type="button"
        @click="advancedOpen = !advancedOpen"
        class="w-full flex items-center justify-between px-3 h-9 text-body"
        data-testid="advanced-toggle"
        :aria-expanded="advancedOpen"
      >
        <span style="color: var(--semantic-text-muted)">Advanced</span>
        <span class="font-mono text-dense" style="color: var(--semantic-text-dim)">
          {{ overrideCount === 0 ? 'nothing overridden' : `${overrideCount} overridden` }}
          {{ advancedOpen ? '▾' : '▸' }}
        </span>
      </button>

      <div
        v-if="advancedOpen"
        class="px-3 pb-3 pt-1 space-y-3 border-t"
        style="border-color: var(--color-border)"
        data-testid="advanced-body"
      >
        <p class="text-dense" :style="helperStyle">
          Every field inherits until you type in it. The ✕ goes back to inheriting.
        </p>

        <!-- Connection (HTTP only) -->
        <template v-if="isHttpBackend">
        <!-- Connection -->
        <div class="font-mono text-micro uppercase tracking-wider pt-1" :style="helperStyle">
          Connection
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Base URL</label>
          <div class="flex gap-2">
            <input
              :value="modelValue.base_url"
              @input="update('base_url', ($event.target as HTMLInputElement).value)"
              type="text"
              :placeholder="`inherit — ${resolved?.base_url || 'provider default'}`"
              :class="inputBase"
              :style="inputStyle(!!errors?.base_url)"
              data-testid="base-url-input"
            />
            <button
              v-if="modelValue.base_url !== ''"
              type="button"
              @click="update('base_url', '')"
              class="w-8 h-8 shrink-0 rounded-md border text-dense"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-dim);
                background-color: transparent;
              "
              aria-label="Clear base URL override"
            >
              ✕
            </button>
          </div>
          <p v-if="errors?.base_url" class="text-dense mt-1" :style="errorStyle">
            {{ errors.base_url }}
          </p>
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Body shape</label>
          <select
            :value="modelValue.url_style"
            @change="update('url_style', ($event.target as HTMLSelectElement).value)"
            :class="inputBase"
            :style="inputStyle()"
            data-testid="url-style-select"
          >
            <option v-if="resolved?.url_style" :value="resolved.url_style">
              inherit — {{ resolved.url_style }}
            </option>
            <option value="openai">openai</option>
            <option value="openai-response">openai-response</option>
            <option value="anthropic">anthropic</option>
          </select>
        </div>
        </template>

        <!-- Claude Code knobs (CLI only). `config_dir` is what makes two
             profiles two different logins. -->
        <template v-if="isClaudeCodeBackend">
          <div class="font-mono text-micro uppercase tracking-wider pt-1" :style="helperStyle">
            Claude Code
          </div>
          <div>
            <label :class="labelBase" :style="labelStyle"
              >Config dir
              <span class="block text-dense mt-0.5" :style="helperStyle">
                CLAUDE_CONFIG_DIR. Blank = ~/.claude. Point two profiles at two dirs to keep two
                logins apart.
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
            <label :class="labelBase" :style="labelStyle"
              >Max turns
              <span class="block text-dense mt-0.5" :style="helperStyle">
                Agentic turn ceiling (--max-turns). Blank = CLI default.
              </span>
            </label>
            <input
              :value="modelValue.max_turns ?? ''"
              @input="
                (e) => {
                  const raw = (e.target as HTMLInputElement).value
                  if (raw === '') return update('max_turns', null)
                  const parsed = parseInt(raw, 10)
                  update('max_turns', Number.isFinite(parsed) ? Math.max(1, parsed) : null)
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
        </template>

        <!-- OpenCode knobs (CLI only). `agent` selects which of the CLI's
             own agents runs the turn; `auto` is what makes a headless run
             possible at all. -->
        <template v-if="isOpencodeBackend">
          <div class="font-mono text-micro uppercase tracking-wider pt-1" :style="helperStyle">
            OpenCode
          </div>
          <div>
            <label :class="labelBase" :style="labelStyle"
              >Agent
              <span class="block text-dense mt-0.5" :style="helperStyle">
                Which opencode agent runs the turn (--agent). Blank = the CLI's default agent.
              </span>
            </label>
            <input
              :value="modelValue.opencode_agent ?? ''"
              @input="
                (e) => {
                  const raw = (e.target as HTMLInputElement).value
                  update('opencode_agent', raw === '' ? null : raw)
                }
              "
              type="text"
              placeholder="build"
              :class="inputBase"
              :style="inputStyle()"
              data-testid="opencode-agent-input"
            />
          </div>
          <div>
            <label :class="labelBase" :style="labelStyle"
              >Auto-approve
              <span class="block text-dense mt-0.5" :style="helperStyle">
                Pass --auto so the CLI does not block on an interactive permission prompt. Off
                means the run stalls waiting for an answer nobody can give.
              </span>
            </label>
            <select
              :value="modelValue.opencode_auto === false ? 'off' : 'on'"
              @change="
                update(
                  'opencode_auto',
                  ($event.target as HTMLSelectElement).value === 'on' ? null : false,
                )
              "
              :class="inputBase"
              :style="inputStyle()"
              data-testid="opencode-auto-select"
            >
              <option value="on">On (--auto)</option>
              <option value="off">Off</option>
            </select>
          </div>
        </template>

        <!-- Behaviour (HTTP only: every field is a request-body knob the
             CLI never sees) -->
        <template v-if="isHttpBackend">
        <!-- Behaviour -->
        <div class="font-mono text-micro uppercase tracking-wider pt-1" :style="helperStyle">
          Behaviour
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Thinking</label>
          <select
            :value="modelValue.thinking"
            @change="update('thinking', ($event.target as HTMLSelectElement).value)"
            :class="inputBase"
            :style="inputStyle()"
            data-testid="thinking-select"
          >
            <option value="auto">inherit — Auto</option>
            <option value="on">On</option>
            <option value="off">Off</option>
          </select>
        </div>
        <div v-if="showsEffort">
          <label :class="labelBase" :style="labelStyle">
            Effort
            <span v-if="resolved?.effort_values?.length" class="font-mono" :style="helperStyle">
              (this model: {{ resolved?.effort_values?.join(' · ') }})
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
            <option value="">inherit — Auto</option>
            <option
              v-for="v in effortOptions.length > 0 ? effortOptions : ['low', 'medium', 'high']"
              :key="v"
              :value="v"
            >
              {{ v }}
            </option>
          </select>
        </div>
        <div
          v-else-if="hasFacts && !modelSupportsReasoning"
          class="text-dense"
          :style="helperStyle"
        >
          This model has no extended-reasoning control.
        </div>
        <div v-if="showsBudget">
          <label :class="labelBase" :style="labelStyle">
            Thinking budget tokens
            <span class="font-mono" :style="helperStyle">
              (min {{ resolved?.budget_min ?? 1024 }})
            </span>
          </label>
          <input
            :value="modelValue.thinking_budget_tokens ?? ''"
            @input="
              (e) => {
                const raw = (e.target as HTMLInputElement).value
                if (raw === '') return update('thinking_budget_tokens', null)
                const parsed = parseInt(raw, 10)
                update(
                  'thinking_budget_tokens',
                  Number.isFinite(parsed) ? Math.max(1024, parsed) : null,
                )
              }
            "
            type="number"
            min="1024"
            step="512"
            :placeholder="`inherit — ${resolved?.budget_min ?? 1024} +`"
            :class="inputBase"
            :style="inputStyle()"
            data-testid="thinking-budget-input"
          />
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Temperature</label>
          <input
            :value="temperatureDraft"
            @input="onTemperatureInput(($event.target as HTMLInputElement).value)"
            type="text"
            inputmode="decimal"
            placeholder="inherit — auto"
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

        </template>

        <!-- Compaction (both backends: the context window matters either way) -->
        <div class="font-mono text-micro uppercase tracking-wider pt-1" :style="helperStyle">
          Compaction
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Threshold (%)</label>
          <div class="flex gap-2">
            <input
              :value="thresholdDraft"
              @input="thresholdDraft = ($event.target as HTMLInputElement).value"
              type="number"
              min="0"
              max="100"
              placeholder="inherit — 80"
              :class="inputBase"
              :style="inputStyle(!!errors?.compaction_threshold_percent)"
              data-testid="profile-threshold-input"
            />
            <button
              v-if="modelValue.compaction_threshold_percent !== null"
              type="button"
              @click="update('compaction_threshold_percent', null)"
              class="w-8 h-8 shrink-0 rounded-md border text-dense"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-dim);
                background-color: transparent;
              "
              aria-label="Clear threshold override"
            >
              ✕
            </button>
          </div>
          <p
            v-if="errors?.compaction_threshold_percent"
            class="text-dense mt-1"
            :style="errorStyle"
          >
            {{ errors.compaction_threshold_percent }}
          </p>
        </div>
        <div>
          <label :class="labelBase" :style="labelStyle">Context window (tokens)</label>
          <div class="flex gap-2">
            <input
              :value="capacityDraft"
              @input="capacityDraft = ($event.target as HTMLInputElement).value"
              type="number"
              min="0"
              step="1000"
              :placeholder="resolved ? `inherit — ${resolved.context_window}` : 'inherit — catalog'"
              :class="inputBase"
              :style="inputStyle(!!errors?.max_capacity_tokens)"
              data-testid="profile-capacity-input"
            />
            <button
              v-if="modelValue.max_capacity_tokens !== null"
              type="button"
              @click="update('max_capacity_tokens', null)"
              class="w-8 h-8 shrink-0 rounded-md border text-dense"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-dim);
                background-color: transparent;
              "
              aria-label="Clear context window override"
            >
              ✕
            </button>
          </div>
          <p v-if="errors?.max_capacity_tokens" class="text-dense mt-1" :style="errorStyle">
            {{ errors.max_capacity_tokens }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>

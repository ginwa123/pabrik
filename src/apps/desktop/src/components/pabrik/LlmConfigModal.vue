<script setup lang="ts">
import { computed, onUpdated, ref } from 'vue'

import { testLlmProfile, type LlmTestResult } from '../../api'
import LlmConfigForm, { type LlmConfig } from './LlmConfigForm.vue'

export interface LlmConfigModalValue {
  name: string
  config: LlmConfig
}

const props = withDefaults(
  defineProps<{
    modelValue: LlmConfigModalValue
    errors?: {
      name?: string
      model?: string
      base_url?: string
      api_key?: string
      /** Plan 2026-07-07-compaction-inline: per-profile compaction
       *  errors. Not currently set by the backend (null is always
       *  valid; > 100 is caught at the HTTP layer), but accepted
       *  by the form so the errors prop type is future-proof. */
      max_capacity_tokens?: string
      compaction_threshold_percent?: string
    }
    title: string
    /** When true, the name field is editable (Add mode). When false (Edit mode), it's disabled. */
    nameEditable: boolean
    /** Optional slot name to render after the LLM config form (e.g. 'extra'). */
    extraSlotName?: string
    /** Tailwind max-width class for the dialog. Default `max-w-md` (28rem). */
    maxWidthClass?: 'max-w-md' | 'max-w-lg' | 'max-w-xl' | 'max-w-2xl' | 'max-w-3xl'
  }>(),
  { maxWidthClass: 'max-w-md' },
)

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfigModalValue]
  cancel: []
  save: []
}>()

function updateName(val: string) {
  testResult.value = null
  emit('update:modelValue', { ...props.modelValue, name: val })
}
function updateConfig(cfg: LlmConfig) {
  // Editing any field invalidates a previous test result — the profile may now be misconfigured
  // even though the prior probe succeeded. Clearing prevents stale "looks good!" badges from
  // lulling the user into saving a broken config.
  testResult.value = null
  emit('update:modelValue', { ...props.modelValue, config: cfg })
}

// ─── Test button state ───────────────────────────────────────────────────── Mirrors
// McpServerModal's probe UX: `testResult` carries the last `POST /api/llm/test` response (null =
// "no probe yet"), `testing` is the loading flag while the HTTP call is in-flight.
const testResult = ref<LlmTestResult | null>(null)
const testing = ref(false)

// Test is enabled when a model is present. api_key is optional —
// keyless local endpoints (Ollama-style) and stub upstreams are valid
// probe targets; the backend omits the auth header when empty.
const testValid = computed(() => props.modelValue.config.model.trim().length > 0)

// Test-result invalidation lives in the edit handlers above
// (`updateName` / `updateConfig`): every keystroke flows through them,
// so a stale probe can never outlive the edit that broke it.
let prevLlmModalValue = props.modelValue
onUpdated(() => {
  // A new modelValue object means the parent reseeded the form (e.g. a
  // different profile to edit) — any probe result describes the previous
  // one and must go.
  if (props.modelValue === prevLlmModalValue) return
  prevLlmModalValue = props.modelValue
  testResult.value = null
})

async function onTest() {
  if (testing.value || !testValid.value) return
  testing.value = true
  testResult.value = null
  try {
    const cfg = props.modelValue.config
    testResult.value = await testLlmProfile({
      model: cfg.model.trim(),
      base_url: cfg.base_url.trim(),
      api_key: cfg.api_key,
      url_style: cfg.url_style,
    })
  } catch (err) {
    // `testLlmProfile` always returns an `LlmTestResult`; this catch
    // only fires for unexpected exceptions (network down, etc.).
    testResult.value = {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }
  } finally {
    testing.value = false
  }
}
</script>

<template>
  <Teleport to="body">
    <div
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5)"
      @click.self="emit('cancel')"
    >
      <div
        :class="['w-full mx-4 rounded-md flex flex-col', props.maxWidthClass]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        role="dialog"
        aria-modal="true"
      >
        <div
          class="flex items-center justify-between px-5 h-12 border-b shrink-0"
          style="border-color: var(--color-border)"
        >
          <div class="flex items-center gap-2 min-w-0">
            <h3 class="text-body font-semibold shrink-0" style="color: var(--semantic-text)">
              {{ title }}
            </h3>
            <!-- Edit mode: the name is NOT editable, so a whole row spent saying
                 "you cannot change this" was waste. It reads as a chip here. -->
            <span
              v-if="!nameEditable && modelValue.name"
              data-testid="profile-name-chip"
              class="text-dense font-mono px-2 h-5 inline-flex items-center rounded-md border truncate"
              :title="modelValue.name"
              style="color: var(--semantic-text-muted); border-color: var(--color-border)"
            >{{ modelValue.name }}</span>
          </div>
          <button
            type="button"
            @click="emit('cancel')"
            aria-label="Close"
            class="w-7 h-7 flex items-center justify-center text-body"
            style="color: var(--semantic-text-muted)"
          >
            ✕
          </button>
        </div>

        <div class="p-5 space-y-4 overflow-y-auto" style="max-height: 70vh">
          <!-- Name — Add mode only; Edit mode shows it in the title. -->
          <div v-if="nameEditable">
            <label
              class="block text-dense font-medium mb-1.5"
              style="color: var(--semantic-text-muted)"
            >
              Name <span style="color: var(--color-red)">*</span>
            </label>
            <input
              :value="modelValue.name"
              @input="updateName(($event.target as HTMLInputElement).value)"
              type="text"
              :disabled="!nameEditable"
              class="w-full px-3 h-8 rounded-md border text-body"
              style="
                background-color: var(--semantic-content-bg);
                color: var(--semantic-text);
                border-color: var(--color-border);
              "
              data-testid="name-input"
            />
            <p v-if="errors?.name" class="text-dense mt-1" style="color: var(--color-red)">
              {{ errors.name }}
            </p>
          </div>

          <!-- LLM config -->
          <LlmConfigForm
            :model-value="modelValue.config"
            :errors="errors"
            @update:model-value="updateConfig"
          />

          <!-- Optional extras (system_prompt, headers, ...) -->
          <slot v-if="extraSlotName" :name="extraSlotName" />

          <!-- Test result panel (mirrors McpServerModal's test-result). -->
          <div
            v-if="testResult"
            data-testid="llm-test-result"
            class="px-3 py-2 rounded-md text-dense border"
            :style="
              testResult.ok
                ? {
                    borderColor: 'var(--color-green)',
                    backgroundColor: 'rgba(34, 197, 94, 0.08)',
                    color: 'var(--semantic-text)',
                  }
                : {
                    borderColor: 'var(--color-red)',
                    backgroundColor: 'rgba(239, 68, 68, 0.08)',
                    color: 'var(--semantic-text)',
                  }
            "
          >
            <div class="flex items-center gap-1.5 font-medium">
              <span v-if="testResult.ok" style="color: var(--color-green)">✓</span>
              <span v-else style="color: var(--color-red)">✗</span>
              <span v-if="testResult.ok">
                Connected — "{{ testResult.reply }}" ({{ testResult.latency_ms }}ms)
              </span>
              <span v-else>Connection failed</span>
            </div>
            <div
              v-if="!testResult.ok"
              data-testid="llm-test-error"
              class="mt-1 font-mono text-meta"
              style="color: var(--semantic-text-muted)"
            >
              {{ testResult.error }}
            </div>
            <div
              v-if="!testResult.ok && testResult.details"
              class="mt-0.5 font-mono text-meta break-all"
              style="color: var(--semantic-text-dim)"
            >
              {{ testResult.details }}
            </div>
          </div>
        </div>

        <div
          class="flex justify-between gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border)"
        >
          <button
            type="button"
            data-testid="llm-test-btn"
            @click="onTest"
            :disabled="!testValid || testing"
            class="px-4 h-8 rounded-md text-body border transition-colors duration-150"
            :style="{
              borderColor: 'var(--color-border)',
              color: testing ? 'var(--semantic-text-dim)' : 'var(--semantic-text)',
              backgroundColor: 'transparent',
              opacity: testValid && !testing ? 1 : 0.5,
              cursor: testValid && !testing ? 'pointer' : 'not-allowed',
            }"
          >
            {{ testing ? 'Testing…' : 'Test' }}
          </button>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="modal-cancel"
              @click="emit('cancel')"
              class="px-4 h-8 rounded-md text-body border transition-colors duration-150"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
            >
              Cancel
            </button>
            <button
              type="button"
              data-testid="modal-save"
              @click="emit('save')"
              class="px-4 h-8 rounded-md text-body font-medium border transition-colors duration-150"
              style="
                border-color: var(--color-violet);
                color: var(--color-violet);
                background-color: transparent;
              "
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
  </Teleport>
</template>

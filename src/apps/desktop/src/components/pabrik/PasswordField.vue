<script setup lang="ts">
/** One password input for the account form: label, masked field with a reveal
 * toggle, a hint line, and the field's own error line. */
import { computed, ref } from 'vue'

const model = defineModel<string>({ required: true })

const props = withDefaults(
  defineProps<{
    /** Used for the label's `for`, the input id and every data-testid. */
    id: string
    label: string
    autocomplete?: string
    hint?: string
    error?: string | null
    disabled?: boolean
  }>(),
  { autocomplete: 'off', hint: '', error: null, disabled: false },
)

const revealed = ref(false)
const inputType = computed<string>(() => (revealed.value ? 'text' : 'password'))
const revealLabel = computed<string>(
  () => `${revealed.value ? 'Hide' : 'Show'} ${props.label.toLowerCase()}`,
)
</script>

<template>
  <div data-testid="password-field">
    <label
      :for="props.id"
      class="block text-dense font-medium mb-1.5"
      style="color: var(--semantic-text)"
    >
      {{ props.label }}
    </label>
    <div class="flex items-center gap-2">
      <input
        :id="props.id"
        v-model="model"
        :type="inputType"
        :autocomplete="props.autocomplete"
        :disabled="props.disabled"
        :aria-invalid="props.error ? 'true' : 'false'"
        :aria-describedby="props.error ? `${props.id}-error` : undefined"
        :data-testid="`input-${props.id}`"
        class="flex-1 min-w-0 h-9 px-3 rounded-md text-body"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
      />
      <button
        type="button"
        :disabled="props.disabled"
        :aria-label="revealLabel"
        :data-testid="`toggle-${props.id}`"
        class="shrink-0 h-9 px-2.5 rounded-md text-dense font-medium cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
        style="
          background-color: var(--semantic-content-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text-muted);
        "
        @click="revealed = !revealed"
      >
        {{ revealed ? 'Hide' : 'Show' }}
      </button>
    </div>
    <p
      v-if="props.error"
      :id="`${props.id}-error`"
      :data-testid="`error-${props.id}`"
      class="text-dense mt-1"
      style="color: var(--color-red)"
    >
      {{ props.error }}
    </p>
    <p v-else-if="props.hint" class="text-dense mt-1" style="color: var(--semantic-text-muted)">
      {{ props.hint }}
    </p>
  </div>
</template>

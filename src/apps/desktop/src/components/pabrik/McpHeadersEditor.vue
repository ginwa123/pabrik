<script setup lang="ts">
import { ref } from 'vue'

import { useSecretAutocomplete } from '../../composables/useSecretAutocomplete'
import { useSecretNames } from '../../helpers/secretNames'
import SecretSuggestionMenu from './SecretSuggestionMenu.vue'

export interface McpHeader { key: string; value: string }

const props = defineProps<{ modelValue: McpHeader[] }>()
const emit = defineEmits<{ 'update:modelValue': [value: McpHeader[]] }>()

function update(idx: number, field: 'key' | 'value', val: string) {
  const next = props.modelValue.map((h, i) => i === idx ? { ...h, [field]: val } : h)
  emit('update:modelValue', next)
}
function add() {
  emit('update:modelValue', [...props.modelValue, { key: '', value: '' }])
}
function remove(idx: number) {
  emit('update:modelValue', props.modelValue.filter((_, i) => i !== idx))
}

const inputBase = 'flex-1 px-3 h-8 rounded-md border text-body font-mono'
const inputStyle = {
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: 'var(--color-border)',
}

const secretRow = ref(-1)
const valueFields = ref<Array<HTMLInputElement | null>>([])

const {
  open: secretMenuOpen,
  items: secretMenuItems,
  active: secretMenuActive,
  onInput: onSecretInput,
  onKeydown: onSecretKeydown,
  choose: chooseSecret,
  close: closeSecretMenu,
} = useSecretAutocomplete({
  names: useSecretNames(),
  commit: (text: string) => {
    if (secretRow.value >= 0) update(secretRow.value, 'value', text)
  },
})

function setValueField(idx: number, el: unknown): void {
  valueFields.value[idx] = (el as HTMLInputElement | null) ?? null
}

function onValueInput(idx: number, field: HTMLInputElement): void {
  secretRow.value = idx
  update(idx, 'value', field.value)
  onSecretInput(field)
}

function onValueKeydown(event: KeyboardEvent, field: HTMLInputElement): void {
  if (onSecretKeydown(event, field)) event.preventDefault()
}

function onSecretPick(name: string): void {
  const field = valueFields.value[secretRow.value]
  if (field) chooseSecret(name, field)
}
</script>

<template>
  <div>
    <div class="flex items-center justify-between mb-2">
      <label class="text-dense font-medium" style="color: var(--semantic-text-muted);">Headers</label>
      <button
        type="button"
        data-testid="add-header"
        @click="add"
        class="text-dense px-2 h-7 rounded-md border transition-colors duration-150"
        style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
      >+ Add header</button>
    </div>

    <p v-if="modelValue.length === 0" class="text-dense italic" style="color: var(--semantic-text-dim);">
      No headers. Click "Add header" for API keys.
    </p>

    <div v-else class="space-y-2">
      <div
        v-for="(h, idx) in modelValue"
        :key="idx"
        data-testid="header-row"
        class="flex gap-2 items-center"
      >
        <input
          :value="h.key"
          @input="update(idx, 'key', ($event.target as HTMLInputElement).value)"
          type="text"
          placeholder="Header-Name"
          :class="inputBase"
          :style="inputStyle"
        />
        <div class="flex-1">
          <input
            :ref="(el) => setValueField(idx, el)"
            :value="h.value"
            @input="onValueInput(idx, $event.target as HTMLInputElement)"
            @keydown="onValueKeydown($event, $event.target as HTMLInputElement)"
            @blur="closeSecretMenu()"
            type="text"
            placeholder="value, or use a workspace secret"
            autocomplete="off"
            class="w-full px-3 h-8 rounded-md border text-body font-mono"
            :style="inputStyle"
            data-testid="header-value-input"
          />
          <SecretSuggestionMenu
            v-if="secretMenuOpen && secretRow === idx"
            :items="secretMenuItems"
            :active="secretMenuActive"
            @pick="onSecretPick"
            @hover="(index: number) => (secretMenuActive = index)"
          />
        </div>
        <button
          type="button"
          data-testid="remove-header"
          @click="remove(idx)"
          aria-label="Remove header"
          class="w-7 h-7 flex items-center justify-center rounded-md text-body transition-colors duration-150"
          style="color: var(--color-red);"
        >✕</button>
      </div>
    </div>
  </div>
</template>

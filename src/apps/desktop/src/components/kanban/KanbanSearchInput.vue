<!--
  KanbanSearchInput — compact search input for the kanban board header.

  Public API (purely presentational):
    props:  modelValue: string   (v-model)
    emits:  update:modelValue [value: string]

  Behaviour:
    - Compact input (w-48 ≈ 192px). Sits to the LEFT of the Settings
      button in the kanban header.
    - Placeholder: "Search tasks…", behind a leading search mark.
    - On input → emits update:modelValue with the new value.
    - On Esc keydown → emits update:modelValue with '' (clears).
    - ✕ clear button appears inside the input when value is non-empty;
      click → emits update:modelValue with ''.

  The component is stateless — the host (KanbanView.vue) owns the
  debounce + refetch logic. Keeps this component trivially testable.

-->
<script setup lang="ts">
import UiIcon from '../ui/UiIcon.vue'

defineProps<{ modelValue: string }>()
const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const onInput = (e: Event) => {
  const value = (e.target as HTMLInputElement).value
  emit('update:modelValue', value)
}

const clear = () => {
  emit('update:modelValue', '')
}

const onKeyDown = (e: KeyboardEvent) => {
  if (e.key === 'Escape') {
    e.preventDefault()
    clear()
  }
}
</script>

<template>
  <div
    class="relative flex items-center"
    data-testid="kanban-search-input-container"
  >
    <UiIcon
      name="search"
      class="absolute left-2 w-3.5 h-3.5 pointer-events-none"
      style="color: var(--semantic-text-dim);"
    />
    <input
      :value="modelValue"
      @input="onInput"
      @keydown="onKeyDown"
      type="text"
      placeholder="Search tasks…"
      class="w-48 pl-7 pr-7 py-1 rounded text-dense outline-none focus:ring-1"
      style="
        background-color: var(--semantic-card-bg);
        border: 1px solid var(--color-border);
        color: var(--semantic-text);
      "
      data-testid="kanban-search-input"
      aria-label="Search tasks by name, description, or tags"
    />
    <button
      v-if="modelValue"
      type="button"
      @click="clear"
      class="absolute right-1 w-5 h-5 flex items-center justify-center rounded hover:opacity-80"
      style="color: var(--semantic-text-dim);"
      data-testid="kanban-search-input-clear"
      aria-label="Clear search"
    >
      <span aria-hidden="true">✕</span>
    </button>
  </div>
</template>
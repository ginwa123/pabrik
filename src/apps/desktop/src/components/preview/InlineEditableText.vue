<!--
  InlineEditableText — click-to-edit text primitive.

  Two modes:
    - Display: shows the current `value` with an optional "✏️"
      pencil on hover; click anywhere on the text (or the pencil)
      to enter edit mode.
    - Edit:    shows an `<input>` pre-filled with the current value,
      auto-focused + selected. Enter saves, Escape cancels, blur
      saves (matching the inline rename patterns in KanbanColumn.vue).

  Public API:
    props:
      value           string   The current value to display / edit.
      placeholder     string   Placeholder for the input (defaults to '').
      maxlength       number   Optional input cap (defaults to 200).
      ariaLabel       string   Required for a11y — describes what
                                is being edited.
      testId          string   Data-testid prefix for the rendered
                                input / display elements.
      displayClass    string   Optional CSS class for the display
                                text (e.g. text-body font-semibold).
                                Defaults to ''.
    emits:
      save    [newValue: string]  Fires on Enter or blur when the
                                   trimmed value is non-empty AND
                                   different from the original.
      cancel  []                   Fires on Escape.

-->
<script setup lang="ts">
import { ref, nextTick } from 'vue'

const props = withDefaults(
  defineProps<{
    value: string
    placeholder?: string
    maxlength?: number
    ariaLabel: string
    testId: string
    displayClass?: string
  }>(),
  {
    placeholder: '',
    maxlength: 200,
    displayClass: '',
  },
)

const emit = defineEmits<{
  save: [newValue: string]
  cancel: []
}>()

const isEditing = ref(false)
const editValue = ref('')
const inputRef = ref<HTMLInputElement | null>(null)

async function startEditing() {
  editValue.value = props.value
  isEditing.value = true
  await nextTick()
  // Focus + select-all so the user can immediately type a new
  // value (or hit Esc to cancel). Mirrors
  // KanbanColumn.vue:startInlineRename (line 109-115).
  inputRef.value?.focus()
  inputRef.value?.select()
}

function cancelEditing() {
  isEditing.value = false
  editValue.value = ''
  emit('cancel')
}

function commitEditing() {
  const trimmed = editValue.value.trim()
  // No-op if empty (caller shouldn't be allowed to blank the
  // value — KanbanSettingsDialog and KanbanView both treat empty
  // as a UI bug rather than a rename intent).
  if (!trimmed) {
    cancelEditing()
    return
  }
  // No-op if unchanged — saves a backend round-trip.
  if (trimmed === props.value) {
    isEditing.value = false
    editValue.value = ''
    return
  }
  isEditing.value = false
  editValue.value = ''
  emit('save', trimmed)
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key === 'Enter') {
    event.preventDefault()
    commitEditing()
  } else if (event.key === 'Escape') {
    event.preventDefault()
    cancelEditing()
  }
}
</script>

<template>
  <span
    class="inline-editable inline-flex items-center gap-1 min-w-0"
    :data-testid="`${testId}-wrapper`"
  >
    <!-- Display mode: hover-revealed pencil + click target on the text -->
    <span
      v-if="!isEditing"
      class="inline-flex items-center gap-1 min-w-0 cursor-text group"
      role="button"
      tabindex="0"
      :aria-label="`Edit ${ariaLabel}`"
      :data-testid="`${testId}-display`"
      @click="startEditing"
      @keydown.enter.prevent="startEditing"
      @keydown.space.prevent="startEditing"
    >
      <span
        class="truncate"
        :class="displayClass"
        :data-testid="`${testId}-value`"
      >{{ value || placeholder }}</span>
      <!-- Pencil — hidden until hover. Mirrors the KanbanColumn
           ⋮ menu hover affordance. -->
      <button
        type="button"
        class="shrink-0 w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover:opacity-70 hover:!opacity-100 transition-opacity duration-150"
        style="color: var(--semantic-text-muted);"
        :aria-label="`Edit ${ariaLabel}`"
        :data-testid="`${testId}-pencil`"
        @click.stop="startEditing"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden="true">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
            d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
    </span>

    <!-- Edit mode: input + Save/Cancel -->
    <span
      v-else
      class="inline-flex items-center gap-1 min-w-0"
      :data-testid="`${testId}-edit`"
    >
      <input
        ref="inputRef"
        v-model="editValue"
        type="text"
        :placeholder="placeholder"
        :maxlength="maxlength"
        :aria-label="`Editing ${ariaLabel}`"
        :data-testid="`${testId}-input`"
        class="flex-1 min-w-0 px-2 py-0.5 rounded text-body outline-none transition-all duration-200"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        @keydown="handleKeydown"
        @blur="commitEditing"
      />
      <button
        type="button"
        class="shrink-0 px-2 py-0.5 rounded text-dense font-medium hover:opacity-80 transition-opacity"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        :aria-label="`Save ${ariaLabel}`"
        :data-testid="`${testId}-save`"
        @mousedown.prevent
        @click.stop="commitEditing"
      >
        Save
      </button>
      <button
        type="button"
        class="shrink-0 px-2 py-0.5 rounded text-dense font-medium hover:opacity-80 transition-opacity"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text-muted);
        "
        :aria-label="`Cancel ${ariaLabel}`"
        :data-testid="`${testId}-cancel`"
        @mousedown.prevent
        @click.stop="cancelEditing"
      >
        Cancel
      </button>
    </span>
  </span>
</template>

<style scoped>
/* Make the entire display block focusable + accessible (hover styles
   on the pencil span are handled by Tailwind's group-hover class). */
.inline-editable :focus-visible {
  outline: 2px solid var(--color-violet);
  outline-offset: 2px;
  border-radius: 4px;
}
</style>
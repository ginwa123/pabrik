<script setup lang="ts">
// One row's description. It shows the stored text, and swaps in an inline editor on click. The
// draft stays local and is emitted only on Save, so a half-typed sentence never reaches the store.
import { nextTick, ref } from 'vue'

const props = withDefaults(
  defineProps<{
    secretId: string
    /** The row's name, for the aria-label. Never rendered from here. */
    name: string
    description?: string
  }>(),
  { description: '' },
)

const emit = defineEmits<{
  /** Write or clear what this credential is for. Never carries the value. */
  save: [payload: { id: string; description: string }]
}>()

/** Mirrors the server's cap, so an over-long description is stopped at the field. */
const MAX_DESCRIPTION_LEN = 500

const editing = ref(false)
const draft = ref('')
const input = ref<HTMLInputElement | null>(null)

async function open(): Promise<void> {
  // Start from the stored text, so editing a sentence means amending it.
  draft.value = props.description
  editing.value = true
  await nextTick()
  input.value?.focus()
}

function close(): void {
  editing.value = false
  draft.value = ''
}

function save(): void {
  emit('save', { id: props.secretId, description: draft.value.trim() })
  close()
}
</script>

<template>
  <div v-if="editing" class="mt-1 flex items-center gap-1.5">
    <input
      ref="input"
      v-model="draft"
      data-testid="description-edit-input"
      type="text"
      autocomplete="off"
      :maxlength="MAX_DESCRIPTION_LEN"
      placeholder="What is this credential for?"
      class="flex-1 min-w-0 px-2 h-7 rounded-md text-dense"
      style="
        background-color: var(--semantic-wash);
        color: var(--semantic-text);
        border: 1px solid var(--color-border);
      "
      @keydown.enter.prevent="save"
      @keydown.esc.prevent="close"
    />
    <button
      type="button"
      data-testid="description-save-btn"
      class="px-2 h-7 rounded-md text-dense border shrink-0 transition-colors duration-150"
      style="
        border-color: var(--color-violet);
        color: var(--color-violet);
        background-color: transparent;
      "
      @click="save"
    >
      Save
    </button>
    <button
      type="button"
      data-testid="description-cancel-btn"
      class="px-2 h-7 rounded-md text-dense shrink-0 transition-colors duration-150"
      style="color: var(--semantic-text-muted)"
      @click="close"
    >
      Cancel
    </button>
  </div>

  <button
    v-else
    type="button"
    data-testid="secret-description"
    class="text-dense mt-0.5 max-w-xl text-left block transition-colors duration-150"
    :class="props.description ? '' : 'italic'"
    :style="{
      color: props.description ? 'var(--semantic-text-muted)' : 'var(--semantic-text-dim)',
    }"
    :aria-label="`Edit what ${props.name} is for`"
    @click="open"
  >
    {{ props.description || '+ Add a description' }}
  </button>
</template>

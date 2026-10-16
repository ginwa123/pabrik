<!--
  RenameDesignPageModal — centered single-input modal for renaming a
  design page from the sidebar tree's ⋮ menu.

  Mirrors RenameTaskModal.vue (same input + Save/Cancel layout, same
  Esc-blur pattern). Lives as its own sibling component rather than
  a generic "RenameModal" because both the visual styling (page-row
  vs. task-row context) and the testid naming ("rename-page-"
  prefix) want to be distinct from the existing task-rename surface.

  Public API:
    props:
      show:         v-model:show — boolean toggle
      currentName:  string — the page's existing name (pre-fills the input)
    emits:
      close:        when the user dismisses via × / backdrop / Cancel / Esc
      rename(name): when the user clicks Save / presses Enter (carries the
                    trimmed, non-empty, value-changed name)
-->
<script setup lang="ts">
import { ref, nextTick, onMounted, onUpdated } from 'vue'

const props = defineProps<{
  show: boolean
  currentName: string
}>()

const emit = defineEmits<{
  close: []
  rename: [name: string]
}>()

const name = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

const handleOpen = async () => {
  name.value = props.currentName
  await nextTick()
  nameInput.value?.focus()
  nameInput.value?.select()
}

const handleClose = () => {
  emit('close')
}

const handleRename = () => {
  const trimmed = name.value.trim()
  // Same guard as RenameTaskModal: only emit when the trimmed value
  // is non-empty AND actually different from the current name. No-op
  // closes the modal silently.
  if (trimmed && trimmed !== props.currentName) {
    emit('rename', trimmed)
  }
  handleClose()
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter' && name.value.trim()) {
    handleRename()
  } else if (event.key === 'Escape') {
    handleClose()
  }
}

// Open-reset without watch(): seed on mount (initial show=true) and on closed->open updates. A
// Transition before-enter hook cannot do this — it never fires on initial mount (no `appear`) and
// VTU stubs Transition, so specs that mount then setProps(show=true) would see empty fields.
const wasShown = ref(props.show)
onMounted(() => {
  if (props.show) void handleOpen()
})
onUpdated(() => {
  if (props.show && !wasShown.value) void handleOpen()
  wasShown.value = props.show
})
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
        @keydown="handleKeydown"
      >
        <!-- Backdrop -->
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="handleClose" />

        <!-- Modal Content -->
        <div
          class="relative w-full max-w-sm mx-4 p-6 rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <!-- Header -->
          <h3 class="text-title-sm font-semibold mb-4" style="color: var(--semantic-text)">
            Rename Page
          </h3>

          <!-- Name Input -->
          <div class="mb-6">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Page Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Page name"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              data-testid="rename-design-page-input"
            />
          </div>

          <!-- Actions -->
          <div class="flex justify-end gap-3">
            <button
              @click="handleClose"
              type="button"
              class="px-4 py-2 rounded-lg text-body font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                color: var(--semantic-text-muted);
              "
              data-testid="rename-design-page-cancel"
            >
              Cancel
            </button>
            <button
              @click="handleRename"
              type="button"
              :disabled="!name.trim() || name.trim() === currentName"
              class="px-4 py-2 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
              data-testid="rename-design-page-save"
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal transitions — shared with RenameTaskModal so both feel the
   same to the user despite the component split. */
.modal-enter-active,
.modal-leave-active {
  transition: all 0.25s ease-out;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95) translateY(10px);
}
</style>

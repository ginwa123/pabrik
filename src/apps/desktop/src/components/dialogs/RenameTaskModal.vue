<script setup lang="ts">
import { ref, nextTick, onMounted, onUpdated } from 'vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    currentName: string
    /**
     * Dialog heading / field label / input placeholder. The defaults say
     * "Task" because the kanban card was the first caller, but the same
     * modal is reused by the sidebar chat-row context menu, where "Rename
     * Task" would name a concept the user is not looking at. Overridable
     * rather than forked so the confirm/cancel/keyboard behaviour stays
     * in one place.
     */
    heading?: string
    label?: string
    placeholder?: string
  }>(),
  {
    heading: 'Rename Task',
    label: 'Task Name',
    placeholder: 'Task name',
  },
)

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
          <h3
            class="text-title-sm font-semibold mb-4"
            style="color: var(--semantic-text)"
            data-testid="rename-modal-heading"
          >
            {{ heading }}
          </h3>

          <!-- Name Input -->
          <div class="mb-6">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              {{ label }}
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              :placeholder="placeholder"
              data-testid="rename-modal-input"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            />
          </div>

          <!-- Actions -->
          <div class="flex justify-end gap-3">
            <button
              @click="handleClose"
              class="px-4 py-2 rounded-lg text-body font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              @click="handleRename"
              :disabled="!name.trim() || name.trim() === currentName"
              data-testid="rename-modal-save"
              class="px-4 py-2 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
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
/* Modal transitions */
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

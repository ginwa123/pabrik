<script setup lang="ts">
import { ref, nextTick, onMounted, onUpdated } from 'vue'

const props = defineProps<{
  show: boolean
  projectName?: string
}>()

const emit = defineEmits<{
  close: []
  create: [name: string, description?: string]
}>()

const name = ref('')
const description = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

const handleOpen = () => {
  name.value = ''
  description.value = ''
  nextTick(() => nameInput.value?.focus())
}

const handleCreate = () => {
  if (name.value.trim()) {
    emit('create', name.value.trim(), description.value.trim() || undefined)
    handleClose()
  }
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
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

        <!-- Dialog Content -->
        <div
          class="relative w-full max-w-sm mx-4 rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">New Task</h3>
            <p v-if="projectName" class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              Add task to "{{ projectName }}"
            </p>
          </div>

          <!-- Task Name Input -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Task Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Enter task name..."
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keydown.enter="handleCreate"
            />
          </div>

          <!-- Task Description Input -->
          <div class="px-5 pb-4">
            <label
              class="block text-dense font-medium mb-2"
              style="color: var(--semantic-text-dim)"
            >
              Description (optional)
            </label>
            <textarea
              v-model="description"
              placeholder="Add a description..."
              rows="3"
              class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 resize-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            />
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              @click="handleCreate"
              :disabled="!name.trim()"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Create Task
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
  transition: all 0.2s ease-out;
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

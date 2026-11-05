<script setup lang="ts">
defineProps<{
  show: boolean
  title?: string
  message: string
  confirmText?: string
  cancelText?: string
}>()

const emit = defineEmits<{
  close: []
  confirm: []
}>()

const handleConfirm = () => {
  emit('confirm')
  emit('close')
}

const handleClose = () => {
  emit('close')
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 bg-black/60 backdrop-blur-sm"
          @click="handleClose"
        />

        <!-- Dialog Content -->
        <div
          class="relative w-full max-w-sm mx-4 rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 class="text-lead font-semibold" style="color: var(--semantic-text);">
              {{ title || 'Confirm' }}
            </h3>
            <p class="text-body mt-2" style="color: var(--semantic-text-muted);">
              {{ message }}
            </p>
          </div>

          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
            >
              {{ cancelText || 'Cancel' }}
            </button>
            <button
              @click="handleConfirm"
              class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 hover:opacity-80"
              style="background-color: var(--semantic-error); color: var(--semantic-on-accent);"
            >
              {{ confirmText || 'Delete' }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
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
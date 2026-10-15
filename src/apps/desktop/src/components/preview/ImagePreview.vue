<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, onUpdated } from 'vue'

/** Full-screen image preview overlay. Renders nothing when `src` is an empty string; otherwise
 * teleports a dimmed backdrop + image + close button to <body>. Clicking the backdrop or pressing
 * Escape emits `close`. */

/** The body scroll is locked while the preview is open so the chat behind it cannot be scrolled.
 * Usage: <ImagePreview :src="previewImageUrl" @close="previewImageUrl = null" /> */
const props = defineProps<{
  src: string
}>()

const emit = defineEmits<{
  close: []
}>()

const isOpen = computed(() => Boolean(props.src))

const lockBodyScroll = () => {
  if (typeof document === 'undefined') return
  const previousOverflow = document.body.style.overflow
  document.body.dataset.imagePreviewPreviousOverflow = previousOverflow
  document.body.style.overflow = 'hidden'
}

const unlockBodyScroll = () => {
  if (typeof document === 'undefined') return
  const previous = document.body.dataset.imagePreviewPreviousOverflow
  if (previous === undefined) {
    document.body.style.overflow = ''
  } else {
    document.body.style.overflow = previous
    delete document.body.dataset.imagePreviewPreviousOverflow
  }
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    event.stopPropagation()
    emit('close')
  }
}

// Body scroll lock + Escape listener follow the open state.

// The open/close transitions originate in the parent (`src` set / `close` emitted), so they are
// picked up here with a prev-value guard on update — same lock/unlock the watcher did; the mount
// call covers the initial state, and onBeforeUnmount below always releases.
function syncOpenLock(open: boolean) {
  if (open) {
    lockBodyScroll()
    document.addEventListener('keydown', handleKeydown)
  } else {
    unlockBodyScroll()
    document.removeEventListener('keydown', handleKeydown)
  }
}

let prevImageOpen = isOpen.value
onMounted(() => {
  prevImageOpen = isOpen.value
  syncOpenLock(isOpen.value)
})
onUpdated(() => {
  if (isOpen.value === prevImageOpen) return
  prevImageOpen = isOpen.value
  syncOpenLock(isOpen.value)
})

onBeforeUnmount(() => {
  unlockBodyScroll()
  document.removeEventListener('keydown', handleKeydown)
})

const onBackdropClick = () => {
  emit('close')
}
</script>

<template>
  <Teleport to="body">
    <Transition name="image-preview-fade">
      <div
        v-if="isOpen"
        class="image-preview-overlay"
        role="dialog"
        aria-modal="true"
        aria-label="Image preview"
        @click="onBackdropClick"
      >
        <div class="image-preview-content" @click.stop>
          <button
            type="button"
            class="image-preview-close"
            aria-label="Close image preview"
            @click="emit('close')"
          >
            <svg
              class="w-6 h-6"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
          <img :src="src" alt="Preview" class="image-preview-img" @click.stop />
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.image-preview-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(0, 0, 0, 0.85);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 9999;
  padding: 20px;
}

.image-preview-content {
  position: relative;
  max-width: 90vw;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.image-preview-close {
  position: absolute;
  top: -40px;
  right: 0;
  background: none;
  border: none;
  color: white;
  cursor: pointer;
  padding: 8px;
  opacity: 0.7;
  transition: opacity 0.2s;
}

.image-preview-close:hover {
  opacity: 1;
}

.image-preview-img {
  max-width: 100%;
  max-height: calc(90vh - 60px);
  object-fit: contain;
  border-radius: 8px;
}

.image-preview-fade-enter-active,
.image-preview-fade-leave-active {
  transition: opacity 0.2s ease;
}

.image-preview-fade-enter-from,
.image-preview-fade-leave-to {
  opacity: 0;
}
</style>

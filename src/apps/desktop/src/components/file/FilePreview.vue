<script setup lang="ts">
import { ref, computed } from 'vue'
import { isDocumentFile } from '@/helpers/fileAttachments'

export interface PreviewFile {
  file: File
  previewUrl: string
}

const props = defineProps<{
  modelValue: PreviewFile[]
  maxHeight?: string
}>()

const emit = defineEmits<{
  'update:modelValue': [files: PreviewFile[]]
  remove: [index: number]
}>()

const hoveredIndex = ref<number | null>(null)
const popupIndex = ref<number | null>(null)

// Computed property for the current popup item
const popupItem = computed(() => {
  if (popupIndex.value === null) return null
  return props.modelValue[popupIndex.value] ?? null
})

const isVideoFile = (file: File): boolean => file.type.startsWith('video/')

const isImageFile = (file: File): boolean => file.type.startsWith('image/')

const removeFile = (index: number) => {
  const newFiles = [...props.modelValue]
  const removed = newFiles.splice(index, 1)[0]
  if (removed) {
    // Revoke the preview URL to free memory
    if (removed.previewUrl.startsWith('blob:')) {
      URL.revokeObjectURL(removed.previewUrl)
    }
  }
  emit('update:modelValue', newFiles)
  emit('remove', index)
}

const openPopup = (index: number) => {
  popupIndex.value = index
}

const closePopup = () => {
  popupIndex.value = null
}
</script>

<template>
  <div v-if="modelValue.length > 0" class="file-preview-container">
    <div class="file-preview-list" :style="maxHeight ? `max-height: ${maxHeight}` : ''">
      <div
        v-for="(item, index) in modelValue"
        :key="index"
        class="preview-item"
        @mouseenter="hoveredIndex = index"
        @mouseleave="hoveredIndex = null"
      >
        <video
          v-if="isVideoFile(item.file)"
          :src="item.previewUrl"
          class="preview-image"
          controls
          preload="metadata"
        />
        <div v-else-if="isDocumentFile(item.file)" class="preview-document">
          <svg class="preview-document-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"
            />
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 2v6h6" />
          </svg>
          <span class="preview-document-name">{{ item.file.name }}</span>
        </div>
        <img
          v-else
          :src="item.previewUrl"
          :alt="item.file.name"
          class="preview-image"
          @click="openPopup(index)"
        />
        <button
          type="button"
          class="remove-btn"
          :class="{ visible: hoveredIndex === index }"
          @click.stop="removeFile(index)"
          title="Remove image"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
        <span class="file-name" :class="{ visible: hoveredIndex === index }">{{
          item.file.name
        }}</span>
      </div>
    </div>

    <!-- Popup modal -->
    <Teleport to="body">
      <div v-if="popupItem" class="popup-overlay" @click="closePopup">
        <div class="popup-content" @click.stop>
          <button type="button" class="popup-close" @click="closePopup">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
          <video
            v-if="isVideoFile(popupItem.file)"
            :src="popupItem.previewUrl"
            class="popup-image"
            controls
            preload="metadata"
          />
          <img
            v-else-if="isImageFile(popupItem.file)"
            :src="popupItem.previewUrl"
            :alt="popupItem.file.name"
            class="popup-image"
          />
          <div v-else class="popup-document">
            <span class="popup-filename">{{ popupItem.file.name }}</span>
            <span class="popup-size">{{ (popupItem.file.size / 1024).toFixed(1) }} KB</span>
          </div>
          <div class="popup-footer">
            <span class="popup-filename">{{ popupItem.file.name }}</span>
            <span class="popup-size">{{ (popupItem.file.size / 1024).toFixed(1) }} KB</span>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.file-preview-container {
  margin-bottom: 8px;
}

.file-preview-list {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  overflow-y: auto;
  padding: 4px;
}

.preview-item {
  position: relative;
  width: 80px;
  height: 80px;
  border-radius: 8px;
  overflow: hidden;
  border: 1px solid var(--color-border);
  background-color: var(--semantic-sidebar-bg);
  cursor: pointer;
}

.preview-image {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.preview-image:hover {
  opacity: 0.9;
}

.preview-document {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 4px;
  width: 100%;
  height: 100%;
  padding: 4px;
  color: var(--color-text);
}

.preview-document-icon {
  width: 24px;
  height: 24px;
}

.preview-document-name {
  font-size: var(--text-micro);
  text-align: center;
  overflow: hidden;
  text-overflow: ellipsis;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.remove-btn {
  position: absolute;
  top: 4px;
  right: 4px;
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background-color: rgba(0, 0, 0, 0.6);
  border: none;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  transition: opacity 0.2s ease;
  color: white;
  padding: 0;
}

.remove-btn.visible {
  opacity: 1;
}

.remove-btn:hover {
  background-color: rgba(220, 38, 38, 0.8);
}

.file-name {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  padding: 2px 4px;
  background: linear-gradient(transparent, rgba(0, 0, 0, 0.7));
  color: white;
  font-size: var(--text-micro);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  opacity: 0;
  transition: opacity 0.2s ease;
}

.file-name.visible {
  opacity: 1;
}

/* Popup modal styles */
.popup-overlay {
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

.popup-content {
  position: relative;
  max-width: 90vw;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.popup-close {
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

.popup-close:hover {
  opacity: 1;
}

.popup-image {
  max-width: 100%;
  max-height: calc(90vh - 60px);
  object-fit: contain;
  border-radius: 8px;
}

.popup-document {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  padding: 24px;
}

.popup-footer {
  margin-top: 12px;
  display: flex;
  gap: 16px;
  align-items: center;
}

.popup-filename {
  color: white;
  font-size: var(--text-body);
}

.popup-size {
  color: rgba(255, 255, 255, 0.6);
  font-size: var(--text-dense);
}
</style>

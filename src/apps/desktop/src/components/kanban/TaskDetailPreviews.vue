<script setup lang="ts">
import FilePreviewModal from './FilePreviewModal.vue'
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const { closeFilePreview, closeImagePopup, cwd, imagePopupUrl, previewFilePath } =
  useTaskDetailContext()
</script>

<template>
  <!-- File preview modal. Mounted at the panel root so it's not
       affected by the parent transition. The path comes from the
       chip click; cwd comes from props (the kanban's filesystem
       root, threaded in from KanbanView.item.path). -->
  <FilePreviewModal
    v-if="previewFilePath"
    :show="previewFilePath !== null"
    :cwd="cwd"
    :file-path="previewFilePath"
    @close="closeFilePreview"
  />

  <!-- Persisted-image gallery preview. Teleported to body so it
       escapes the dialog overflow. Opened by clicking a gallery
       thumbnail (imagePopupUrl). Esc / backdrop-click closes it. -->
  <Teleport to="body">
    <div
      v-if="imagePopupUrl"
      class="fixed inset-0 z-[10000] flex items-center justify-center bg-black/85 p-5"
      data-testid="kanban-task-detail-image-popup-overlay"
      @click="closeImagePopup"
    >
      <button
        type="button"
        class="absolute top-2 right-2 p-2 text-white opacity-70 hover:opacity-100 transition-opacity"
        aria-label="Close image preview"
        @click.stop="closeImagePopup"
      >
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M6 18L18 6M6 6l12 12"
          />
        </svg>
      </button>
      <img
        :src="imagePopupUrl"
        alt="Task image preview"
        class="max-w-full max-h-full object-contain rounded-lg"
        data-testid="kanban-task-detail-image-popup-img"
        @click.stop
      />
    </div>
  </Teleport>
</template>

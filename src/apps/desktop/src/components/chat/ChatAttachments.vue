<script setup lang="ts">
/** The attachment strip on a user turn: one fixed-size thumbnail per attached image, one player per
 * attached clip, click an image to open the lightbox. Extracted from `ChatView.vue` so the `src`
 * binding is reachable by a mount test. */
import { computed } from 'vue'
import { renderableMediaUrls } from '../../helpers/mediaUrls'
import { parseFileAttachmentsMeta } from '../../helpers/fileAttachments'

const props = defineProps<{
  imageUrls?: string[]
  videoUrls?: string[]
  /** The attached files as a JSON array of `{name, mime, bytes}` — metadata only. */
  fileAttachments?: string
}>()

/** The attached documents, as the read path reports them — never the bytes. */
const attachedFiles = computed(() => parseFileAttachmentsMeta(props.fileAttachments))

const emit = defineEmits<{
  (e: 'open-image', url: string): void
}>()
</script>

<template>
  <div class="mb-2">
    <div class="flex flex-wrap gap-2">
      <div
        v-for="(imgUrl, imgIdx) in renderableMediaUrls(imageUrls)"
        :key="`img-${imgIdx}`"
        class="chat-attached-image-thumb"
        @click="emit('open-image', imgUrl)"
      >
        <img
          :src="imgUrl"
          alt="Attached image"
          width="80"
          height="80"
          class="chat-attached-image-img"
        />
      </div>
      <div
        v-for="(file, fileIdx) in attachedFiles"
        :key="`file-${fileIdx}`"
        class="chat-attached-file-chip"
      >
        <svg
          class="chat-attached-file-icon"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"
          />
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14 2v6h6" />
        </svg>
        <span class="chat-attached-file-name">{{ file.name }}</span>
        <span class="chat-attached-file-size">{{ (file.bytes / 1024).toFixed(1) }} KB</span>
      </div>
      <div
        v-for="(vidUrl, vidIdx) in renderableMediaUrls(videoUrls)"
        :key="`vid-${vidIdx}`"
        class="chat-attached-image-thumb"
      >
        <video
          :src="vidUrl"
          width="160"
          class="chat-attached-image-img"
          controls
          preload="metadata"
        />
      </div>
    </div>
  </div>
</template>

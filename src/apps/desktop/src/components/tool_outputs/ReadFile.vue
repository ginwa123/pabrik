<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import ToolParameters from './_shared/ToolParameters.vue'
import ImagePreview from '../preview/ImagePreview.vue'
import {
  parseReadFile,
  normalizeToolContent,
  basenameOfPath,
  formatBytes,
} from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'
import { detectLanguage, highlightLine, type Token } from '@/helpers/codeHighlight'

const props = defineProps<{
  content: unknown
  expanded?: boolean
  cwd?: string
  parameters?: string
  /** The picture the backend attached to this tool result (`llm_history.image_url`, decoded
   * into a list by the chat view). An image read carries no text content at all, so this is
   * the only place the bytes exist. */
  imageUrls?: string[]
}>()

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseReadFile(normalized.value.data)
  if (normalized.value.error) {
    p.success = false
    p.error = normalized.value.error
  }
  return p
})

// Display the parsed content; the parser already strips XML wrappers.
const fileContent = computed(() => parsed.value.content || '')

// Raw content lines. A single trailing "" produced by a final "\n" is
// a split artifact, not a real line — drop it so the gutter stays exact.
const contentLines = computed(() => {
  const c = fileContent.value
  if (!c) return []
  const lines = c.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  return lines
})

// 1-indexed display number of the first line. The backend's start_line
// is a 0-indexed offset, so line i renders as baseLine + i.
const baseLine = computed(() => (parsed.value.startLine ?? 0) + 1)

const lineCount = computed(() => contentLines.value.length)

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty content, but we know the path.
const isRunning = computed(() => {
  const c = props.content
  const isEmpty =
    c === null ||
    c === undefined ||
    (typeof c === 'string' && c.trim().length === 0) ||
    (typeof c === 'object' && !Array.isArray(c) && Object.keys(c).length === 0)
  return isEmpty && displayPath.value !== null
})

// The picture itself. The backend inlines it as a `data:` URL on the tool result, so no
// download round-trip is needed (and none would work: the download endpoint sandboxes to
// the session cwd, while a screenshot often lives outside it).
const imageSrc = computed((): string | null => {
  for (const url of props.imageUrls ?? []) {
    if (typeof url === 'string' && url.trim() !== '') return url
  }
  return null
})

// The payload declares an image even when the data URL never arrived (a row persisted
// before the backend attached it). The card must say so instead of claiming "(empty)".
const declaredImageMime = computed((): string | null => {
  const mime = parsed.value.mime
  return mime && mime.toLowerCase().startsWith('image/') ? mime : null
})

const isImageRead = computed(() => imageSrc.value !== null || declaredImageMime.value !== null)

const imageMeta = computed((): string => {
  const mime = declaredImageMime.value ?? 'image'
  const bytes = parsed.value.bytes
  return bytes === null ? mime : `${mime} · ${formatBytes(bytes)}`
})

const imageAlt = computed((): string => {
  const path = displayPath.value
  return path ? basenameOfPath(path) : 'image'
})

// An image read has no text to read, so the picture IS the answer: the card opens itself
// when one arrives. A user toggle wins from then on — derived, never watched (the desktop
// app bans `watch`).
const userExpanded = ref<boolean | null>(null)
const isExpanded = computed(
  () => userExpanded.value ?? (isImageRead.value || (props.expanded ?? false)),
)

// An inline image has no intrinsic size until it decodes, so the card would pop taller
// mid-scroll. Reserve the space until load (an error counts as arrived — the img hides
// itself and the reserve must drop too).
const imageLoaded = ref(false)
const fullscreenSrc = ref<string | null>(null)

// Language for code coloring, derived from the file path. Unknown
// extensions fall back to plaintext (plain-text rendering, exactly as before).
const fileLanguage = computed(() => detectLanguage(displayPath.value ?? ''))

// Per-line tokens for code coloring. Tokens render as framework text
// nodes (never HTML strings), so file content cannot inject markup.
const highlightedLines = computed((): Token[][] => {
  const lang = fileLanguage.value
  return contentLines.value.map((line) => highlightLine(line, lang))
})

const rightMeta = computed((): string => {
  if (isRunning.value) return 'running…'
  if (parsed.value.error) return 'Error'
  if (isImageRead.value) return imageMeta.value
  return `${lineCount.value}L`
})

const handleToggle = (next: boolean) => {
  userExpanded.value = next
}

const openFullscreen = () => {
  fullscreenSrc.value = imageSrc.value
}

const closeFullscreen = () => {
  fullscreenSrc.value = null
}

const onImageLoad = () => {
  imageLoaded.value = true
}

const onImageError = (e: Event) => {
  ;(e.target as HTMLImageElement).style.display = 'none'
  imageLoaded.value = true
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-[var(--tint-error-border)] opacity-80': !!parsed.error }"
  >
    <ToolCardHeader
      tool-name="read_file"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="rightMeta"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div
        v-if="parsed.error"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-error)] text-dense"
      >
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <div
        v-else-if="imageSrc"
        class="flex justify-center rounded bg-[var(--semantic-wash-strong)] p-1.5"
        :class="{ 'min-h-40 items-center animate-pulse': !imageLoaded }"
        data-testid="read-file-image"
      >
        <img
          :src="imageSrc"
          :alt="imageAlt"
          class="max-h-96 w-full cursor-zoom-in rounded object-contain"
          data-testid="read-file-image-img"
          @click="openFullscreen"
          @load="onImageLoad"
          @error="onImageError"
        />
      </div>
      <div
        v-else-if="contentLines.length > 0"
        class="p-2 m-0 bg-[var(--semantic-wash)] overflow-x-auto leading-relaxed text-[var(--semantic-text)] text-dense"
      >
        <div
          v-for="(tokens, idx) in highlightedLines"
          :key="idx"
          class="flex hover:bg-[var(--tint-accent)]"
        >
          <span
            class="rf-gutter min-w-[3rem] text-right mr-3 text-[var(--semantic-text-dim)] select-none shrink-0"
            >{{ baseLine + idx }}</span
          >
          <span class="rf-line whitespace-pre"
            ><span v-for="(tok, tIdx) in tokens" :key="tIdx" :class="'tok-' + tok.type">{{
              tok.text || ' '
            }}</span></span
          >
        </div>
      </div>
      <pre
        v-else-if="declaredImageMime"
        class="p-2 m-0 bg-[var(--semantic-wash)] whitespace-pre-wrap leading-relaxed text-[var(--semantic-text-dim)] text-dense"
        data-testid="read-file-image-missing"
        >{{ imageMeta }} — the picture was not attached to this result. Read the file again to see
        it.</pre>
      <pre
        v-else
        class="p-2 m-0 bg-[var(--semantic-wash)] whitespace-pre overflow-x-visible leading-relaxed text-[var(--semantic-text)] text-dense hover:bg-[var(--tint-accent)]"
      >
(empty)</pre>
      <ToolParameters :parameters="parameters" />
    </div>

    <ImagePreview :src="fullscreenSrc ?? ''" @close="closeFullscreen" />
  </div>
</template>

<!--
  KanbanDescriptionEditor — Markdown-aware description editor for kanban
  tasks. Extracted from KanbanTaskDetailDialog's inline <textarea> block
  so the dialog can swap between this component (edit mode) and
  <MarkdownDescription> (display mode) without re-rendering the form.

  Features (mirrored from FileInput.vue patterns where applicable):
    - Markdown text v-model on the textarea.
    - Image paste (Ctrl/Cmd+V) with cross-browser fallback for WebKitGTK
      (uses the same clipboardData.items + navigator.clipboard.read
      strategy as FileInput.vue).
    - Paperclip button → hidden <input type="file" accept="image/*"
      multiple>.
    - @-trigger file picker that fetches via /api/system/folder
      recursive scan and inserts `@/path` at the cursor.

  Storage format:
    The modelValue is a Markdown string. Pasted/picked images are
    encoded as `![filename](data:image/<ext>;base64,<payload>)` directly
    in the markdown — self-contained, no upload endpoint, no image
    table. Downscales images larger than MAX_IMAGE_BYTES via <canvas>.

  Cap strategy:
    Text length is UNLIMITED by default (no maxlength enforcement —
    the DB TEXT column accepts multi-MB). An optional `maxLength`
    prop remains for callers that want a cap (counter renders
    `<len> / <max>` when set, `<len> chars` when unset). Image
    size is bounded per-image by MAX_IMAGE_BYTES (4 MB).

  Create mode (taskId=''):
    The dialog opens this editor with taskId='' before the task
    exists on the server. Pasted/picked images are STAGED in
    `previewFiles` (visual) and `pendingFiles` (data, exposed via
    defineExpose). The textarea is NOT modified — we never write
    `data:image/png;base64,…` into the description, which would
    store multi-MB base64 in the DB TEXT column. After the task
    is created, the dialog's host
    reads `pendingFiles`, uploads each via `api.uploadTaskAttachment`,
    and patches the description with `![name](<url>)` markdown.
    See docs/superpowers/plans/2026-08-06-kanban-no-base64-in-desc.md.
-->
<script setup lang="ts">
import { ref, computed, nextTick, onMounted, onBeforeUnmount, onUpdated } from 'vue'
import FilePreview, { type PreviewFile } from '../file/FilePreview.vue'
import UiIcon from '../ui/UiIcon.vue'
import * as api from '../../api'

interface FileEntry {
  name: string
  path: string
  isDirectory: boolean
}

const props = withDefaults(
  defineProps<{
    modelValue: string
    cwd: string
    // Required for image upload. The kanban task id is used as the upload bucket — files land in
    // `<item.path>/.pabrik/attachments/<taskId>/<n>.<ext>`.
    // Empty string disables image upload (the editor still works for text + @path references).
    taskId?: string
    // Optional cap. `undefined` (default) = unlimited, no maxlength
    // enforcement. When set, the textarea enforces it via `maxlength`
    // and the counter renders `<len> / <max>`.
    maxLength?: number
    placeholder?: string
    testId?: string
  }>(),
  {
    taskId: '',
    maxLength: undefined,
    placeholder: 'Add a description…',
    testId: 'kanban-description-editor',
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: string]
}>()

// ─── State ────────────────────────────────────────────────────────────── Local editable copy of
// the prop (uncontrolled between parent syncs: typing works even when the parent does not
// round-trip our emits, e.g. in specs that mount without v-model).
const text = ref(props.modelValue)
let lastSeenText = props.modelValue
const commitText = (v: string): void => {
  text.value = v
  lastSeenText = v
  emit('update:modelValue', v)
}
const previewFiles = ref<PreviewFile[]>([])
// Files staged in CREATE mode (taskId='') — uploaded by the host AFTER the task exists. Mirrors
// previewFiles but exists only for the create-mode flow; in edit mode it stays empty because
// uploads happen inline (see addImageFile).
const pendingFiles = ref<PreviewFile[]>([])
const showFilePicker = ref(false)
const fileQuery = ref('')
const fileList = ref<FileEntry[]>([])
const isLoadingFiles = ref(false)
const selectedFileIndex = ref(0)
const fileDebounceTimer: { value: ReturnType<typeof setTimeout> | null } = { value: null }
const textareaRef = ref<HTMLTextAreaElement | null>(null)
const nativeFileInput = ref<HTMLInputElement | null>(null)
const filePickerRef = ref<HTMLElement | null>(null)

// Caps
const MAX_IMAGE_BYTES = 4 * 1024 * 1024

const counterText = computed<string>(() =>
  props.maxLength != null
    ? `${text.value.length} / ${props.maxLength}`
    : `${text.value.length} chars`,
)

// ─── @-trigger file picker ──────────────────────────────────────────────
// Ported 1:1 from FileInput.vue Task 2 (plan:
// N-sequential-fetch full-tree walk (`loadAllFiles`, deleted).
let fileSearchTimer: ReturnType<typeof setTimeout> | null = null
let fileSearchGen = 0
let fileSearchAbort: AbortController | null = null
// Per-cwd cache for EMPTY-query top-N only (bounded: max 3 cwds, oldest
// evicted). Non-empty queries always hit the server (fresh ranking).
const fileSearchCache = new Map<string, FileEntry[]>()
const FILE_SEARCH_CACHE_MAX_CWDS = 3
// Total entries returned by the server for the current query (footer Y).
const serverTotal = ref(0)
// True when the server errored and `filteredFiles` falls back to the
// client subsequence filter over the cached top-N.
const serverFailed = ref(false)

onBeforeUnmount(() => {
  if (fileDebounceTimer.value) clearTimeout(fileDebounceTimer.value)
  if (fileSearchTimer) clearTimeout(fileSearchTimer)
  fileSearchAbort?.abort()
})

const setFileSearchCache = (cwd: string, entries: FileEntry[]) => {
  if (!fileSearchCache.has(cwd) && fileSearchCache.size >= FILE_SEARCH_CACHE_MAX_CWDS) {
    const oldest = fileSearchCache.keys().next()
    if (!oldest.done) fileSearchCache.delete(oldest.value)
  }
  fileSearchCache.set(cwd, entries)
}

// Server rows are snake_case (`is_directory`); legacy raw-walk rows were
// camelCase (`isDirectory`). Accept both so mixed shapes never render a
// dir with the file mark.
const toRelativeFileEntry = (
  rootPath: string,
  entry: { name: string; path: string; is_directory?: boolean; isDirectory?: boolean },
): FileEntry => ({
  name: entry.name,
  path: entry.path.startsWith(rootPath) ? entry.path.slice(rootPath.length) : entry.path,
  isDirectory: entry.is_directory ?? entry.isDirectory ?? false,
})

const runFileSearch = async (cwd: string, query: string, gen: number, signal: AbortSignal) => {
  isLoadingFiles.value = true
  try {
    const data = await api.searchFiles(cwd, query, 50, 8, signal)
    if (gen !== fileSearchGen) return // stale — superseded by a newer query
    const mapped = (data.entries ?? []).map((e) => toRelativeFileEntry(cwd, e))
    fileList.value = mapped
    serverTotal.value = mapped.length
    serverFailed.value = false
    if (query === '') setFileSearchCache(cwd, mapped)
  } catch {
    if (gen !== fileSearchGen) return // stale — superseded, stay silent
    if (signal.aborted) return // cancelled on retype/close — expected, silent
    // Error fallback: client subsequence filter over the cached top-N.
    serverFailed.value = true
    fileList.value = fileSearchCache.get(cwd) ?? []
    serverTotal.value = fileList.value.length
  } finally {
    if (gen === fileSearchGen) isLoadingFiles.value = false
  }
}

const scheduleFileSearch = (immediate: boolean) => {
  if (fileSearchTimer) {
    clearTimeout(fileSearchTimer)
    fileSearchTimer = null
  }
  // Cancel any in-flight request (retype/close) — the generation counter
  // below discards responses that still resolve afterwards.
  fileSearchAbort?.abort()
  const run = () => {
    const cwd = props.cwd
    const query = fileQuery.value
    if (!cwd || !showFilePicker.value) return
    // Empty-query cache hit: sync, no network.
    if (query === '' && fileSearchCache.has(cwd)) {
      const cached = fileSearchCache.get(cwd)!
      fileList.value = cached
      serverTotal.value = cached.length
      serverFailed.value = false
      isLoadingFiles.value = false
      return
    }
    fileSearchGen++
    const gen = fileSearchGen
    fileSearchAbort = new AbortController()
    void runFileSearch(cwd, query, gen, fileSearchAbort.signal)
  }
  if (immediate) run()
  else fileSearchTimer = setTimeout(run, 150)
}

const closeFilePicker = () => {
  showFilePicker.value = false
  fileQuery.value = ''
  if (fileSearchTimer) {
    clearTimeout(fileSearchTimer)
    fileSearchTimer = null
  }
  fileSearchAbort?.abort()
  fileSearchGen++ // invalidate in-flight responses
  isLoadingFiles.value = false
}

// Out-of-order char match (FileInput pattern): "comp" matches
// "components" because all chars appear in order, not contiguously.
// Used ONLY as the server-error fallback (operates on cached top-N).
const matchesOutOfOrder = (path: string, query: string): boolean => {
  const lowerPath = path.toLowerCase()
  const lowerQuery = query.toLowerCase()
  let pathIdx = 0
  let queryIdx = 0
  while (queryIdx < lowerQuery.length && pathIdx < lowerPath.length) {
    if (lowerPath[pathIdx] === lowerQuery[queryIdx]) queryIdx++
    pathIdx++
  }
  return queryIdx === lowerQuery.length
}

const filteredFiles = computed<FileEntry[]>(() => {
  // Server results are already ranked + filtered — use them directly.
  if (!serverFailed.value) return fileList.value
  if (!fileQuery.value) return fileList.value
  const q = fileQuery.value.toLowerCase()
  return fileList.value.filter((f) => matchesOutOfOrder(f.path, q))
})

// Render cap: at most 50 rows in the DOM (v1 — no virtual list).
const visibleFiles = computed(() => filteredFiles.value.slice(0, 50))

const detectAtTrigger = () => {
  if (!textareaRef.value) return
  const pos = textareaRef.value.selectionStart ?? 0
  const textBeforeCursor = text.value.slice(0, pos)
  const atMatch = textBeforeCursor.match(/@([\w./\\:-]*)$/)
  if (atMatch) {
    const q = atMatch[1] ?? ''
    const wasOpen = showFilePicker.value
    const queryChanged = q !== fileQuery.value
    fileQuery.value = q
    if (!wasOpen) {
      showFilePicker.value = true
      selectedFileIndex.value = 0
      scheduleFileSearch(true) // immediate on open
    } else if (queryChanged) {
      selectedFileIndex.value = 0
      scheduleFileSearch(false) // debounced 150ms on retype
    }
  } else {
    closeFilePicker()
  }
}

const selectFile = (file: FileEntry) => {
  if (!textareaRef.value) return
  const pos = textareaRef.value.selectionStart ?? 0
  const before = text.value.slice(0, pos)
  const after = text.value.slice(pos)
  // Strip the `@` trigger token but keep the file path verbatim (e.g. `/src/main.zig` inserts as-is
  // — no `@` prefix). The path chip detector in <MarkdownDescription> matches `/path/to/file`
  // directly, so a leading `@` is unnecessary noise.
  const atMatch = before.match(/@([\w./\\:-]*)$/)
  const insertText = file.path
  if (atMatch && atMatch.index !== undefined) {
    commitText(before.slice(0, atMatch.index) + insertText + after)
  } else {
    commitText(before + insertText + after)
  }
  showFilePicker.value = false
  fileQuery.value = ''
  nextTick(() => {
    if (!textareaRef.value) return
    const newPos = (atMatch?.index ?? before.length) + insertText.length
    textareaRef.value.setSelectionRange(newPos, newPos)
    textareaRef.value.focus()
  })
}

const handleTextareaInput = () => {
  if (fileDebounceTimer.value) clearTimeout(fileDebounceTimer.value)
  fileDebounceTimer.value = setTimeout(detectAtTrigger, 150)
}

const scrollSelectedIntoView = () => {
  setTimeout(() => {
    // Scoped to this picker's DOM node (not document) so sibling chat
    // tabs / kanban editors never steal the scroll target.
    const root = filePickerRef.value
    if (!root) return
    const buttons = root.querySelectorAll('button')
    const selectedBtn = buttons[selectedFileIndex.value]
    if (selectedBtn) {
      selectedBtn.scrollIntoView({ behavior: 'auto', block: 'nearest' })
    }
  }, 50)
}

const handleKeydown = (e: KeyboardEvent) => {
  if (!showFilePicker.value) return
  const files = filteredFiles.value
  if (e.key === 'ArrowDown') {
    e.preventDefault()
    e.stopPropagation()
    selectedFileIndex.value = Math.min(selectedFileIndex.value + 1, files.length - 1)
    scrollSelectedIntoView()
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    e.stopPropagation()
    selectedFileIndex.value = Math.max(selectedFileIndex.value - 1, 0)
    scrollSelectedIntoView()
  } else if (e.key === 'Enter') {
    e.preventDefault()
    e.stopPropagation()
    const selectedFile = files[selectedFileIndex.value]
    if (selectedFile) {
      selectFile(selectedFile)
    }
  } else if (e.key === 'Escape') {
    e.stopPropagation()
    closeFilePicker()
  } else if (e.key === 'Tab') {
    e.preventDefault()
    e.stopPropagation()
    const selectedFile = files[selectedFileIndex.value]
    if (selectedFile) {
      selectFile(selectedFile)
    }
  }
}

const onTextareaInput = (event: Event) => {
  const target = event.target as HTMLTextAreaElement
  commitText(target.value)
  handleTextareaInput()
  autoResize(event)
}

// ─── Image paste (mirrors FileInput.vue strategy 1 + 2) ────────────────
const isImageFile = (file: File): boolean => file.type.startsWith('image/')
const isVideoFile = (file: File): boolean => file.type.startsWith('video/')
const isMediaFile = (file: File): boolean => isImageFile(file) || isVideoFile(file)
const MAX_VIDEO_BYTES = 25 * 1024 * 1024

const fileToDataUrl = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = reject
    reader.readAsDataURL(file)
  })

const downscaleIfTooLarge = async (file: File): Promise<File> => {
  if (file.type.startsWith('video/')) return file
  if (file.size <= MAX_IMAGE_BYTES) return file
  // Downscale via canvas to ~max 1920px wide while keeping aspect ratio.
  const dataUrl = await fileToDataUrl(file)
  const img = await new Promise<HTMLImageElement>((resolve, reject) => {
    const i = new Image()
    i.onload = () => resolve(i)
    i.onerror = reject
    i.src = dataUrl
  })
  const maxWidth = 1920
  const scale = Math.min(1, maxWidth / img.width)
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(img.width * scale)
  canvas.height = Math.round(img.height * scale)
  const ctx = canvas.getContext('2d')
  if (!ctx) return file
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
  const out = canvas.toDataURL('image/jpeg', 0.85)
  // Convert data URL back to a File object so PreviewFile's previewUrl
  // stays a blob: URL (preview thumbnail), separate from the markdown
  // payload (data: URL).
  const blob = await (await fetch(out)).blob()
  return new File([blob], file.name.replace(/\.[^.]+$/, '.jpg'), {
    type: 'image/jpeg',
  })
}

const addImageFile = async (file: File) => {
  if (!isMediaFile(file)) return
  if (isVideoFile(file) && file.size > MAX_VIDEO_BYTES) return
  const downscaled = await downscaleIfTooLarge(file)

  // Show a preview slot so the user sees the image they just pasted.
  // The blob URL is cheap and revoked on preview-removal (see
  // handlePreviewUpdate).
  const previewUrl = URL.createObjectURL(downscaled)
  const previewEntry: PreviewFile = { file: downscaled, previewUrl }
  previewFiles.value.push(previewEntry)

  if (!props.taskId) {
    // CREATE MODE — the task doesn't exist on the server yet, so there's no taskId to upload to.
    pendingFiles.value.push(previewEntry)
    return
  }

  // EDIT MODE (Migration 069 — kanban image urls column). The task exists on the server. We stage
  // the new image in `pendingFiles` and let the host PATCH the new column (`image_urls`) on Save —
  // same orchestration as create mode.
  pendingFiles.value.push(previewEntry)
  return
}

const handlePaste = async (event: ClipboardEvent) => {
  const items = event.clipboardData?.items
  let pastedImageCount = 0
  if (items && items.length > 0) {
    for (const item of items) {
      if (item.kind !== 'file') continue
      if (!item.type.startsWith('image/') && !item.type.startsWith('video/')) continue
      const file = item.getAsFile()
      if (!file) continue
      const renamed = file.name
        ? file
        : new File([file], `pasted-image-${Date.now()}.${item.type.split('/')[1] ?? 'png'}`, {
            type: item.type,
          })
      await addImageFile(renamed)
      pastedImageCount++
    }
  }
  // WebKitGTK fallback — sync path often yields 0 files for image paste.
  if (pastedImageCount === 0 && navigator.clipboard?.read) {
    try {
      const clipboardItems = await navigator.clipboard.read()
      for (const ci of clipboardItems) {
        for (const type of ci.types) {
          if (!type.startsWith('image/') && !type.startsWith('video/')) continue
          const blob = await ci.getType(type)
          const file = new File(
            [blob],
            `pasted-image-${Date.now()}.${type.split('/')[1] ?? 'png'}`,
            { type },
          )
          await addImageFile(file)
          pastedImageCount++
        }
      }
    } catch (err) {
      console.debug('[paste] clipboard.read fallback skipped:', err)
    }
  }
  if (pastedImageCount > 0) event.preventDefault()
}

// ─── Native file picker (paperclip) ────────────────────────────────────
const triggerFilePicker = () => {
  nativeFileInput.value?.click()
}

const handleNativeFileSelect = async (event: Event) => {
  const target = event.target as HTMLInputElement
  const files = target.files
  if (!files || files.length === 0) return
  for (const file of Array.from(files)) {
    if (!file) continue
    if (!isMediaFile(file)) continue
    await addImageFile(file)
  }
  target.value = ''
}

// ─── Preview removal — strips the matching data URL from the markdown ──
const handlePreviewUpdate = (newFiles: PreviewFile[]) => {
  // Find removed files (in old but not in new).
  const removed = previewFiles.value.filter((old) => !newFiles.includes(old))
  if (removed.length === 0) {
    previewFiles.value = newFiles
    return
  }
  for (const r of removed) {
    if (r.previewUrl.startsWith('blob:')) URL.revokeObjectURL(r.previewUrl)
    // In edit mode the description carries an `![name](<url>)` block we need to strip — same logic
    // as before. In create mode the description never received a markdown block (the file is only
    // in previewFiles/pendingFiles), so the regex find/replace is a safe no-op (nothing matches).
    const fileName = r.file.name
    const escapedName = fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const blockRegex = new RegExp(`!\\[${escapedName}\\]\\([^)]+\\)`, 'g')
    commitText(text.value.replace(blockRegex, '').replace(/[ \t]+(\n|$)/g, '$1'))
    // Drop the corresponding entry from pendingFiles (create mode).
    // The user's intent on removing a preview is "don't upload this either" — otherwise the host
    // would silently upload a file the user already discarded.
    const pendingIdx = pendingFiles.value.findIndex((p) => p.previewUrl === r.previewUrl)
    if (pendingIdx !== -1) pendingFiles.value.splice(pendingIdx, 1)
  }
  previewFiles.value = newFiles
}

// ─── Mount: re-hydrate previewFiles from existing modelValue ───────────
// Decode a `data:<mime>;base64,<payload>` URL into a File. Avoids
// `fetch(dataUrl)` because jsdom does not implement data: URL fetch.
const dataUrlToFile = (dataUrl: string, name: string): File => {
  const [meta, base64] = dataUrl.split(',')
  const mimeMatch = meta?.match(/data:([^;]+)/)
  const mime = mimeMatch ? mimeMatch[1]! : 'image/png'
  const binary = atob(base64 ?? '')
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  const ext = mime.split('/')[1] ?? 'png'
  return new File([bytes], name || `pasted-image-${Date.now()}.${ext}`, { type: mime })
}

// Fetch a server-side attachment and convert it to a File for the
// preview thumbnail. Uses fetch() which jsdom supports (unlike
// data: URLs).
const serverUrlToFile = async (url: string, filename: string): Promise<File | null> => {
  try {
    const response = await fetch(url)
    if (!response.ok) return null
    const blob = await response.blob()
    // Detect MIME from the response (or fall back to extension guess).
    const mime = blob.type || guessMimeFromFilename(filename)
    return new File([blob], filename, { type: mime })
  } catch {
    return null
  }
}

const guessMimeFromFilename = (filename: string): string => {
  const dot = filename.lastIndexOf('.')
  const ext = dot >= 0 ? filename.slice(dot + 1).toLowerCase() : ''
  if (ext === 'png') return 'image/png'
  if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg'
  if (ext === 'gif') return 'image/gif'
  if (ext === 'webp') return 'image/webp'
  if (ext === 'svg') return 'image/svg+xml'
  if (ext === 'bmp') return 'image/bmp'
  return 'application/octet-stream'
}

const rehydratePreviews = () => {
  // Match both inline data: URLs (legacy / fallback) and server-side
  // attachment URLs.
  const imageRegex =
    /!\[([^\]]*)\]\((data:image\/[^)]+|[^)]+\.(?:png|jpg|jpeg|gif|webp|svg|bmp))\)/g
  const matches = [...text.value.matchAll(imageRegex)]
  if (matches.length === 0) return
  for (const m of matches) {
    const alt = m[1] ?? ''
    const url = m[2] ?? ''
    if (url.startsWith('data:')) {
      try {
        const file = dataUrlToFile(url, alt)
        const previewUrl = URL.createObjectURL(file)
        previewFiles.value.push({ file, previewUrl })
      } catch (err) {
        console.warn('[rehydrate] failed to load inline image', err)
      }
    } else {
      // Server-side attachment — fetch async, push when ready.
      void (async () => {
        const filename = url.split('/').pop() ?? 'attachment'
        const file = await serverUrlToFile(url, filename)
        if (!file) return
        const previewUrl = URL.createObjectURL(file)
        previewFiles.value.push({ file, previewUrl })
      })()
    }
  }
}

onMounted(() => {
  // Only rehydrate if there's existing image content (i.e. editing an
  // existing task). For empty modelValue the for-loop above is a no-op.
  rehydratePreviews()
})

// ─── Rehydrate on external modelValue changes (e.g. dialog re-open) ── We only re-hydrate when the
// modelValue grows (new image added externally). `lastSeenText` is set by the bridge setter above,
// so the parent's round-trip echo of our own keystrokes is recognised and skipped here.
const prevModelValue = ref(props.modelValue)
onUpdated(() => {
  const v = props.modelValue
  if (v === prevModelValue.value) return
  prevModelValue.value = v
  // Mirror externally-changed props into the editable copy (mount seeds it; this covers dialog
  // re-opens with new content).
  if (v !== text.value) {
    text.value = v
    emit('update:modelValue', v)
  }
  if (v === lastSeenText) return
  lastSeenText = v
  // Only re-hydrate when the new value contains image references
  // (inline data: OR server-side attachment URLs) and the preview
  // list is currently empty (avoids duplicate previews).
  if (previewFiles.value.length === 0 && /!\[.*?\]\(((data:image\/|\/api\/))/.test(v)) {
    rehydratePreviews()
  }
})

const autoResize = (event: Event) => {
  const target = event.target as HTMLTextAreaElement
  target.style.height = 'auto'
  target.style.height = `${Math.min(target.scrollHeight, 400)}px`
}

// Expose `pendingFiles` to the parent dialog so it can pass the staged files up to the host's
// create-then-upload orchestrator. See KanbanDescriptionEditor.spec.ts for the pendingFiles
// contract (5 tests).
defineExpose({ pendingFiles })
</script>

<template>
  <div :data-testid="testId">
    <!-- File picker dropdown (above the textarea) -->
    <div
      v-if="showFilePicker && (filteredFiles.length > 0 || isLoadingFiles)"
      ref="filePickerRef"
      class="file-picker-list mb-2 p-2 rounded-lg shadow-lg max-h-72 overflow-y-auto"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      tabindex="0"
    >
      <!-- Loading state (driven by the request lifecycle, not fileList) -->
      <div v-if="isLoadingFiles" class="p-4 text-center">
        <div
          class="w-6 h-6 border-2 rounded-full animate-spin mx-auto mb-2"
          style="border-color: var(--color-violet); border-top-color: transparent"
        />
        <p class="text-body" style="color: var(--semantic-text-dim)">Searching…</p>
      </div>
      <div
        v-else-if="filteredFiles.length === 0"
        class="p-2 text-body"
        style="color: var(--semantic-text-dim)"
      >
        No files found
      </div>
      <div v-else>
        <button
          v-for="(file, idx) in visibleFiles"
          :key="file.path"
          type="button"
          class="w-full text-left px-3 py-1.5 rounded text-body flex items-center gap-2 transition-colors"
          :class="idx === selectedFileIndex ? 'file-item-selected' : ''"
          :style="
            idx === selectedFileIndex
              ? 'background-color: var(--color-violet); color: var(--color-bg);'
              : 'color: var(--semantic-text);'
          "
          @click="selectFile(file)"
          @mouseenter="selectedFileIndex = idx"
        >
          <UiIcon :name="file.isDirectory ? 'folder' : 'file'" />
          <span class="truncate font-mono text-dense">{{ file.path }}</span>
        </button>
      </div>
      <!-- Footer info (render cap vs server total) -->
      <div
        v-if="!isLoadingFiles && filteredFiles.length > 0"
        class="px-3 py-1.5 text-dense rounded mt-1"
        style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-dim)"
      >
        showing {{ visibleFiles.length }} of {{ serverTotal }} files
      </div>
    </div>

    <!-- Image preview list -->
    <FilePreview
      :model-value="previewFiles"
      max-height="120px"
      @update:model-value="handlePreviewUpdate"
    />

    <!-- Textarea + paperclip -->
    <div class="flex gap-2 items-end">
      <textarea
        ref="textareaRef"
        :value="text"
        :placeholder="placeholder"
        :maxlength="maxLength ?? undefined"
        :data-testid="testId"
        rows="6"
        class="flex-1 px-3 py-2.5 rounded-lg text-body outline-none transition-all duration-200 resize-y"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
          font-family: inherit;
          min-height: 160px;
        "
        @input="onTextareaInput"
        @keydown="handleKeydown"
        @paste="handlePaste"
      />
      <button
        type="button"
        :data-testid="`${testId}-paperclip`"
        @click="triggerFilePicker"
        class="shrink-0 w-10 h-10 rounded-lg flex items-center justify-center transition-colors"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        title="Attach image"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.586a6 6 0 108.486 8.486L20.5 13"
          />
        </svg>
      </button>
    </div>

    <!-- Hidden native file input -->
    <input
      ref="nativeFileInput"
      type="file"
      accept="image/*,video/*"
      multiple
      class="hidden"
      @change="handleNativeFileSelect"
    />

    <!-- Char counter -->
    <div
      class="text-micro mt-1 text-right"
      :data-testid="`${testId}-counter`"
      style="color: var(--semantic-text-dim)"
    >
      {{ counterText }}
    </div>
  </div>
</template>

<style scoped>
.file-item-selected {
  /* Hover state styling */
}
</style>

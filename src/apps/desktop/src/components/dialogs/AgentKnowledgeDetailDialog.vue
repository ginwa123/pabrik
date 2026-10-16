<!--
  AgentKnowledgeDetailDialog — modal for editing an existing knowledge
  entry. Opened from AgentView's per-row ✎ button via AppLayout.

  Editable fields:
    - label (always)
    - mode switch (File ↔ Text), mirroring the add dialog's tabs:
        * Text mode  → edit the inline content textarea
        * File mode  → edit the absolute file_path (+ Browse picker)
    - Switching modes PATCHes BOTH file_path and content in one call
      so the row flips cleanly (backend stores them independently;
      content column is NOT NULL DEFAULT '' so '' = file-backed).

  Public API:
    props:  show (boolean), row (AgentKnowledgeRow | null),
            busy (boolean), error (string | null)
    emits:  close,
            save(knowledgeId: string, updates: {
              label: string
              file_path?: string
              content?: string
            })
            — file_path/content are included per the SELECTED mode:
              text mode sends {label, content, file_path: ''},
              file mode sends {label, file_path, content: ''}.
              Always sending both keeps the row XOR-consistent after
              a mode switch (matches the create endpoint's invariant).

  Plan: 2026-08-22-agent-mode-ui-ux (Feature A2, extended per user:
  full edit incl. mode switch).
-->
<script setup lang="ts">
import { ref, computed, nextTick, onMounted, onUpdated } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry, type AgentKnowledgeRow } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    row: AgentKnowledgeRow | null
    busy?: boolean
    error?: string | null
  }>(),
  { busy: false, error: null },
)

const emit = defineEmits<{
  close: []
  save: [
    knowledgeId: string,
    updates: { label: string; file_path?: string; content?: string },
  ]
}>()

const mode = ref<'file' | 'text'>('text')
const label = ref('')
const content = ref('')
const filePath = ref('')
const pathTouched = ref(false)
const showPicker = ref(false)
const labelInput = ref<HTMLInputElement | null>(null)
const pathInput = ref<HTMLInputElement | null>(null)

// The row's CURRENT mode at open time (content non-empty = inline).
const rowIsInline = computed(() => !!props.row && !!props.row.content)

// Absolute on either platform: POSIX `/...` or Windows `C:\...`, `C:/...`, UNC `\\server\share` /
// `//server/share`. Mirrors AgentKnowledgeDialog.vue + backend resolvePath + FilePickerDialog
// isWindowsAbs. POSIX inputs behave byte-identically to the old startsWith('/') check.
function isAbsolutePath(p: string): boolean {
  if (!p) return false
  if (p.startsWith('/')) return true
  if (/^[A-Za-z]:[\\/]/.test(p)) return true
  if (p.startsWith('\\\\') || p.startsWith('//')) return true
  return false
}

const pathError = computed<string | null>(() => {
  if (mode.value !== 'file' || !pathTouched.value) return null
  if (filePath.value.length === 0) return 'Path is required'
  if (!isAbsolutePath(filePath.value)) return 'Path must be absolute'
  return null
})

const canSubmit = computed(() => {
  if (props.busy || !props.row) return false
  if (label.value.trim().length === 0) return false
  if (mode.value === 'file') {
    return filePath.value.length > 0 && isAbsolutePath(filePath.value)
  }
  return content.value.trim().length > 0
})

const handleSave = () => {
  if (!canSubmit.value || !props.row) return
  // Always send BOTH source fields so a mode switch flips the row
  // cleanly (the backend PATCHes only the provided keys; sending ''
  // for the inactive one mirrors the create endpoint's XOR state).
  const updates =
    mode.value === 'text'
      ? { label: label.value, content: content.value, file_path: '' }
      : { label: label.value, file_path: filePath.value, content: '' }
  emit('save', props.row.id, updates)
}

const handleClose = () => {
  if (props.busy) return
  showPicker.value = false
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && !props.busy && !showPicker.value) handleClose()
}

const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  // Same convention as AgentKnowledgeDialog: '' → system root.
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleFileSelected = (path: string) => {
  filePath.value = path
  pathTouched.value = true
  showPicker.value = false
  pathInput.value?.focus()
}

// Seed fields from the row on every open. Runs as the Transition's
// before-enter hook; props are readable here, so the body moves as-is.
const handleOpen = async () => {
  if (props.row) {
    mode.value = rowIsInline.value ? 'text' : 'file'
    label.value = props.row.label
    content.value = props.row.content
    filePath.value = props.row.file_path
    pathTouched.value = false
    showPicker.value = false
    await nextTick()
    labelInput.value?.focus()
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
    <Transition name="agent-knowledge-detail-modal">
      <div
        v-if="show && row"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-knowledge-detail-title"
        data-testid="agent-knowledge-detail-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 id="agent-knowledge-detail-title" class="text-lead font-semibold" style="color: var(--semantic-text);">
              Edit Knowledge
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim);">
              Update the label, the source text, or switch between file and inline text.
            </p>
            <div class="flex gap-1 mt-3" role="tablist" data-testid="agent-knowledge-detail-mode-tabs">
              <button type="button" role="tab" :aria-selected="mode === 'file'"
                @click="mode = 'file'" :disabled="props.busy"
                data-testid="agent-knowledge-detail-mode-file"
                class="text-dense px-2.5 py-1 rounded-md font-medium disabled:opacity-50"
                :style="mode === 'file'
                  ? 'background: var(--color-violet); color: var(--color-bg);'
                  : 'background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'">
                <UiIcon name="file" /> File
              </button>
              <button type="button" role="tab" :aria-selected="mode === 'text'"
                @click="mode = 'text'" :disabled="props.busy"
                data-testid="agent-knowledge-detail-mode-text"
                class="text-dense px-2.5 py-1 rounded-md font-medium disabled:opacity-50"
                :style="mode === 'text'
                  ? 'background: var(--color-violet); color: var(--color-bg);'
                  : 'background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'">
                <UiIcon name="write" /> Text
              </button>
            </div>
          </div>
          <div class="px-5 pb-4 space-y-4 overflow-y-auto">
            <div>
              <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Label</label>
              <input
                ref="labelInput"
                v-model="label"
                type="text"
                placeholder="Project spec"
                data-testid="agent-knowledge-detail-label"
                class="w-full px-3 py-2 rounded-lg text-body outline-none"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
                @keyup.enter="handleSave"
              />
            </div>
            <div v-if="mode === 'file'">
              <div class="flex items-center justify-between mb-2">
                <label class="text-dense font-medium" style="color: var(--semantic-text-dim);">File Path (absolute)</label>
                <button
                  type="button"
                  @click="showPicker = true"
                  data-testid="agent-knowledge-detail-browse"
                  class="text-meta font-medium px-2 py-0.5 rounded hover:opacity-80"
                  style="background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
                  :disabled="props.busy"
                >
                  <UiIcon name="folder-open" /> Browse…
                </button>
              </div>
              <input
                ref="pathInput"
                v-model="filePath"
                type="text"
                placeholder="/home/me/docs/spec.md"
                data-testid="agent-knowledge-detail-path"
                :aria-invalid="pathError !== null"
                class="w-full px-3 py-2 rounded-lg text-body font-mono outline-none"
                :style="{
                  backgroundColor: 'var(--semantic-sidebar-bg)',
                  border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                  color: 'var(--semantic-text)',
                }"
                @input="pathTouched = true"
                @blur="pathTouched = true"
                @keyup.enter="handleSave"
              />
              <p v-if="pathError" class="text-dense mt-1" style="color: var(--color-red);" data-testid="agent-knowledge-detail-path-error">
                {{ pathError }}
              </p>
            </div>
            <div v-else>
              <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Knowledge text</label>
              <textarea
                v-model="content"
                rows="8"
                placeholder="Knowledge text…"
                data-testid="agent-knowledge-detail-content"
                class="w-full px-3 py-2 rounded-lg text-body outline-none resize-y"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
              ></textarea>
            </div>
          </div>
          <div v-if="props.error" data-testid="agent-knowledge-detail-error" class="mx-5 mb-3 text-dense p-2 rounded" style="background: var(--color-red); color: var(--color-bg);">
            {{ props.error }}
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button type="button" @click="handleClose" :disabled="props.busy" data-testid="agent-knowledge-detail-cancel" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);">Cancel</button>
            <button type="button" @click="handleSave" :disabled="!canSubmit" data-testid="agent-knowledge-detail-save" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);">
              <span v-if="props.busy">Saving…</span>
              <span v-else>Save</span>
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <FilePickerDialog
    v-model="showPicker"
    mode="file"
    :load-items="loadItemsForPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="true"
    title="Select Knowledge Markdown File"
    @select="handleFileSelected"
  />
</template>

<style scoped>
.agent-knowledge-detail-modal-enter-active,
.agent-knowledge-detail-modal-leave-active {
  transition: opacity 0.2s ease;
}
.agent-knowledge-detail-modal-enter-from,
.agent-knowledge-detail-modal-leave-to {
  opacity: 0;
}
</style>

<!--
  AgentKnowledgeDialog — modal for adding a knowledge entry to an Agent.

  Two modes (tab toggle):
    - file: file_path (required, must be absolute) + optional label.
      Browse button opens FilePickerDialog.
    - text: inline manual text (required, non-empty) + optional label.

  Public API:
    props:  show (boolean), busy (boolean), error (string | null)
    emits:  close, create(filePath: string, label: string, content: string)
            — file mode passes content=''; text mode passes filePath=''.

  Plan: 2026-08-15-agent-mode (Task 16)
  Updated 2026-08-20 to support `busy` + `error` so AppLayout can
  show submit progress + server error without unmounting the dialog.
  Also added a "Browse" button that opens FilePickerDialog in 'file'
  mode — typing absolute paths by hand is error-prone.
  Updated 2026-08-21 (plan 2026-08-21-agent-knowledge-manual-text):
  added the File/Text mode toggle + textarea for inline knowledge;
  `create` emit gained the `content` arg.
  Updated 2026-09-05 (Windows cwd fix): path validation accepts Windows
  absolutes (`C:\...`, `C:/...`, UNC `\\server\share`) in addition to
  POSIX `/...` — the old `startsWith('/')` check rejected every Windows
  pick with "Path must be absolute" and disabled submit.
-->
<script setup lang="ts">
import { ref, computed, nextTick, onMounted, onUpdated } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(
  defineProps<{ show: boolean; busy?: boolean; error?: string | null }>(),
  { busy: false, error: null },
)

const emit = defineEmits<{
  close: []
  create: [filePath: string, label: string, content: string]
}>()

const mode = ref<'file' | 'text'>('file')
const filePath = ref('')
const label = ref('')
const content = ref('')
const pathInput = ref<HTMLInputElement | null>(null)
const pathTouched = ref(false)
const showPicker = ref(false)

// Absolute on either platform: POSIX `/...` or Windows `C:\...`,
// `C:/...`, UNC `\\server\share` / `//server/share`. Mirrors the
// backend's resolvePath + the FilePickerDialog isWindowsAbs helper.
function isAbsolutePath(p: string): boolean {
  if (!p) return false
  if (p.startsWith('/')) return true
  if (/^[A-Za-z]:[\\/]/.test(p)) return true
  if (p.startsWith('\\\\') || p.startsWith('//')) return true
  return false
}

/** Basename across both `/` and `\` separators. */
function basenameOf(p: string): string {
  const segs = p.split(/[\\/]/).filter(Boolean)
  return segs.length > 0 ? (segs[segs.length - 1] as string) : p
}

const pathError = computed<string | null>(() => {
  if (!pathTouched.value) return null
  if (filePath.value.length === 0) return 'Path is required'
  if (!isAbsolutePath(filePath.value)) return 'Path must be absolute'
  return null
})

const canSubmit = computed(() => {
  if (props.busy) return false
  if (mode.value === 'file') {
    return filePath.value.length > 0 && isAbsolutePath(filePath.value)
  }
  return content.value.trim().length > 0
})

const handleCreate = () => {
  if (!canSubmit.value) return
  // Don't close the dialog here — let the parent decide based on the
  // server response. The parent toggles `show=false` on success.
  emit('create', mode.value === 'file' ? filePath.value : '', label.value, mode.value === 'text' ? content.value : '')
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
  // FilePickerDialog calls this with `''` on first open (to list the system root) and with a folder
  // path when the user navigates. Empty path → use `getSystemFolder` (same pattern as
  // AddAgentDialog) because the backend rejects `path=''` in /system/folder.
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleFileSelected = (path: string) => {
  filePath.value = path
  pathTouched.value = true
  showPicker.value = false
  // Auto-fill the label from the basename if empty.
  if (!label.value.trim()) {
    const base = basenameOf(path)
    const dot = base.lastIndexOf('.')
    label.value = dot > 0 ? base.slice(0, dot) : base
  }
  pathInput.value?.focus()
}

// Reset state on every open. Runs as the Transition's before-enter
// hook so the fields are seeded before the dialog paints.
const handleOpen = async () => {
  mode.value = 'file'
  filePath.value = ''
  label.value = ''
  content.value = ''
  pathTouched.value = false
  showPicker.value = false
  await nextTick()
  pathInput.value?.focus()
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
    <Transition name="agent-knowledge-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-knowledge-title"
        data-testid="agent-knowledge-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 id="agent-knowledge-title" class="text-lead font-semibold" style="color: var(--semantic-text);">
              Add Knowledge
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim);">
              {{ mode === 'file'
                ? 'Attach a markdown file the agent will read at chat start'
                : 'Write or paste text the agent will read at chat start' }}
            </p>
            <div class="flex gap-1 mt-3" role="tablist" data-testid="agent-knowledge-mode-tabs">
              <button type="button" role="tab" :aria-selected="mode === 'file'"
                @click="mode = 'file'" :disabled="props.busy"
                data-testid="agent-knowledge-mode-file"
                class="text-dense px-2.5 py-1 rounded-md font-medium disabled:opacity-50"
                :style="mode === 'file'
                  ? 'background: var(--color-violet); color: var(--color-bg);'
                  : 'background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'">
                <UiIcon name="file" /> File
              </button>
              <button type="button" role="tab" :aria-selected="mode === 'text'"
                @click="mode = 'text'" :disabled="props.busy"
                data-testid="agent-knowledge-mode-text"
                class="text-dense px-2.5 py-1 rounded-md font-medium disabled:opacity-50"
                :style="mode === 'text'
                  ? 'background: var(--color-violet); color: var(--color-bg);'
                  : 'background: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'">
                <UiIcon name="write" /> Text
              </button>
            </div>
          </div>
          <div v-if="mode === 'file'" class="px-5 pb-4">
            <div class="flex items-center justify-between mb-2">
              <label class="text-dense font-medium" style="color: var(--semantic-text-dim);">File Path (absolute)</label>
              <button
                type="button"
                @click="showPicker = true"
                data-testid="agent-knowledge-browse"
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
              data-testid="agent-knowledge-path"
              :aria-invalid="pathError !== null"
              class="w-full px-3 py-2 rounded-lg text-body font-mono outline-none"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="pathTouched = true"
              @blur="pathTouched = true"
              @keyup.enter="handleCreate"
            />
            <p v-if="pathError" class="text-dense mt-1" style="color: var(--color-red);" data-testid="agent-knowledge-path-error">
              {{ pathError }}
            </p>
          </div>
          <div v-else class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Knowledge text</label>
            <textarea
              v-model="content"
              rows="6"
              placeholder="Paste or write the knowledge the agent should read at chat start…"
              data-testid="agent-knowledge-content"
              class="w-full px-3 py-2 rounded-lg text-body outline-none resize-y"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            ></textarea>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Label (optional)</label>
            <input
              v-model="label"
              type="text"
              placeholder="Project spec"
              data-testid="agent-knowledge-label"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            />
          </div>
          <div v-if="props.error" data-testid="agent-knowledge-error" class="mx-5 mb-3 text-dense p-2 rounded" style="background: var(--color-red); color: var(--color-bg);">
            {{ props.error }}
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button type="button" @click="handleClose" :disabled="props.busy" data-testid="agent-knowledge-cancel" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);">Cancel</button>
            <button type="button" @click="handleCreate" :disabled="!canSubmit" data-testid="agent-knowledge-submit" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);">
              <span v-if="props.busy">Adding…</span>
              <span v-else>Add</span>
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
.agent-knowledge-modal-enter-active,
.agent-knowledge-modal-leave-active {
  transition: opacity 0.2s ease;
}
.agent-knowledge-modal-enter-from,
.agent-knowledge-modal-leave-to {
  opacity: 0;
}
</style>
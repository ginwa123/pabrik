<!--
  AddAgentDialog — modal for creating a new Agent workspace item.

  Mirrors AddKanbanDialog: name input + folder picker (required).
  Agent has a cwd like Kanban/Design per spec D11.

  Public API:
    props:  show (boolean)
    emits:  close, create(name: string, path: string)

  Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md
-->
<script setup lang="ts">
import { ref, computed, nextTick, onBeforeUnmount, onMounted, onUpdated } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{ show: boolean }>()

const emit = defineEmits<{
  close: []
  create: [name: string, path: string]
}>()

const name = ref('')
const selectedPath = ref('')
const showPicker = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)
const nameTouched = ref(false)
const pathTouched = ref(false)

const nameError = computed<string | null>(() => {
  if (!nameTouched.value) return null
  if (name.value.trim().length === 0) return 'Name is required'
  return null
})

const pathError = computed<string | null>(() => {
  if (!pathTouched.value) return null
  if (selectedPath.value.length === 0) return 'Folder is required (agents need a cwd)'
  return null
})

const loadItemsForPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleFolderSelected = (path: string) => {
  selectedPath.value = path
  pathTouched.value = true
  showPicker.value = false
}

const handleCreate = () => {
  const trimmedName = name.value.trim()
  if (trimmedName && selectedPath.value) {
    emit('create', trimmedName, selectedPath.value)
    handleClose()
  }
}

const handleClose = () => emit('close')

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

const handleOpen = async () => {
  name.value = ''
  selectedPath.value = ''
  showPicker.value = false
  nameTouched.value = false
  pathTouched.value = false
  await nextTick()
  nameInput.value?.focus()
}

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})

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
    <Transition name="add-agent-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-agent-title"
        data-testid="add-agent-dialog"
      >
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6)"
          @click="handleClose"
        />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            max-height: 70vh;
          "
        >
          <div class="px-5 pt-5 pb-4">
            <h3
              id="add-agent-title"
              class="text-lead font-semibold flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <UiIcon name="robot" />
              Add Agent
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim)">
              Create an Agent — a chatbot with knowledge files and a tool allowlist
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim)"
              >Agent Name</label
            >
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="My Agent"
              data-testid="add-agent-name"
              :aria-invalid="nameError !== null"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${nameError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="nameTouched = true"
              @blur="nameTouched = true"
              @keyup.enter="handleCreate"
            />
            <p v-if="nameError" class="text-dense mt-1" style="color: var(--color-red)">
              {{ nameError }}
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim)"
              >Folder (cwd)</label
            >
            <button
              type="button"
              @click="showPicker = true; pathTouched = true"
              data-testid="add-agent-choose-folder"
              class="w-full px-3 py-2 rounded-lg text-body flex items-center justify-between gap-2"
              :style="{
                backgroundColor: selectedPath
                  ? 'var(--semantic-active-bg)'
                  : 'var(--semantic-sidebar-bg)',
                border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: selectedPath ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
              }"
            >
              <span class="truncate flex-1 text-left font-mono" :title="selectedPath">
                {{ selectedPath || 'Choose folder...' }}
              </span>
              <span
                v-if="selectedPath"
                class="text-dense shrink-0"
                style="color: var(--semantic-text-dim)"
                >Browse</span
              >
              <UiIcon
                v-else
                name="folder-open"
                class="w-4 h-4 shrink-0"
                style="color: var(--semantic-text-dim)"
              />
            </button>
            <p v-if="pathError" class="text-dense mt-1" style="color: var(--color-red)">
              {{ pathError }}
            </p>
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              @click="handleClose"
              data-testid="add-agent-cancel"
              class="px-3 py-1.5 rounded-lg text-body font-medium"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @click="handleCreate"
              :disabled="!name.trim() || !selectedPath"
              data-testid="add-agent-submit"
              class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <FilePickerDialog
    v-model="showPicker"
    mode="folder"
    :load-items="loadItemsForPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="true"
    title="Select Agent Cwd"
    @select="handleFolderSelected"
  />
</template>

<style scoped>
.add-agent-modal-enter-active,
.add-agent-modal-leave-active {
  transition: opacity 0.2s ease;
}
.add-agent-modal-enter-from,
.add-agent-modal-leave-to {
  opacity: 0;
}
</style>

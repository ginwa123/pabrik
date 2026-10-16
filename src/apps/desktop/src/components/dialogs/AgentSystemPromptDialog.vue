<!--
  AgentSystemPromptDialog — modal for adding/editing a system-prompt
  block on an Agent (Migration 080).

  Used for BOTH add and edit:
    - row prop null  → add mode  → emits create(title, content)
    - row prop set   → edit mode → emits save(promptId, {title, content})

  Public API:
    props:  show (boolean), row (AgentSystemPromptRow | null),
            busy (boolean), error (string | null)
    emits:  close, create(title, content), save(promptId, updates)

  Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
  Task: task_1787408958280_1
-->
<script setup lang="ts">
import { ref, computed, nextTick, onMounted, onUpdated } from 'vue'
import type { AgentSystemPromptRow } from '../../api'

const props = withDefaults(
  defineProps<{
    show: boolean
    row?: AgentSystemPromptRow | null
    busy?: boolean
    error?: string | null
  }>(),
  { row: null, busy: false, error: null },
)

const emit = defineEmits<{
  close: []
  create: [title: string, content: string]
  save: [promptId: string, updates: { title: string; content: string }]
}>()

const title = ref('')
const content = ref('')
const titleInput = ref<HTMLInputElement | null>(null)

const isEdit = computed(() => props.row !== null)

const canSubmit = computed(() => {
  if (props.busy) return false
  return content.value.trim().length > 0
})

const handleSubmit = () => {
  if (!canSubmit.value) return
  // Don't close the dialog here — let the parent decide based on the
  // server response. The parent toggles `show=false` on success.
  if (props.row) {
    emit('save', props.row.id, { title: title.value, content: content.value })
  } else {
    emit('create', title.value, content.value)
  }
}

const handleClose = () => {
  if (props.busy) return
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && !props.busy) handleClose()
}

// Populate on every open. Runs as the open-sync guard below,
// which also covers the mount-with-show=true case the old
// { immediate: true } watcher handled.
const handleOpen = async () => {
  // Populate from the row in edit mode; blank in add mode.
  title.value = props.row?.title ?? ''
  content.value = props.row?.content ?? ''
  await nextTick()
  titleInput.value?.focus()
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
    <Transition name="agent-system-prompt-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-system-prompt-title"
        data-testid="agent-system-prompt-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 id="agent-system-prompt-title" class="text-lead font-semibold" style="color: var(--semantic-text);">
              {{ isEdit ? 'Edit System Prompt' : 'Add System Prompt' }}
            </h3>
            <p class="text-dense mt-1" style="color: var(--semantic-text-dim);">
              Injected into every chat with this Agent, before its knowledge.
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Title</label>
            <input
              ref="titleInput"
              v-model="title"
              type="text"
              placeholder="Persona"
              data-testid="agent-system-prompt-title"
              class="w-full px-3 py-2 rounded-lg text-body outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            />
          </div>
          <div class="px-5 pb-4">
            <label class="block text-dense font-medium mb-2" style="color: var(--semantic-text-dim);">Prompt</label>
            <textarea
              v-model="content"
              rows="10"
              placeholder="You are a senior Zig engineer who…"
              data-testid="agent-system-prompt-content"
              class="w-full px-3 py-2 rounded-lg text-body outline-none resize-y"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            ></textarea>
          </div>
          <div v-if="props.error" data-testid="agent-system-prompt-error" class="mx-5 mb-3 text-dense p-2 rounded" style="background: var(--color-red); color: var(--color-bg);">
            {{ props.error }}
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button type="button" @click="handleClose" :disabled="props.busy" data-testid="agent-system-prompt-cancel" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);">Cancel</button>
            <button type="button" @click="handleSubmit" :disabled="!canSubmit" data-testid="agent-system-prompt-submit" class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);">
              <span v-if="props.busy">Saving…</span>
              <span v-else>{{ isEdit ? 'Save' : 'Add' }}</span>
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.agent-system-prompt-modal-enter-active,
.agent-system-prompt-modal-leave-active {
  transition: opacity 0.2s ease;
}
.agent-system-prompt-modal-enter-from,
.agent-system-prompt-modal-leave-to {
  opacity: 0;
}
</style>

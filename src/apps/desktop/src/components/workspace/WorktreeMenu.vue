<script setup lang="ts">
/** Dropdown menu for the git indicator in the chat status bar. */
import { ref, onMounted, onUnmounted } from 'vue'
import UiIcon from '../ui/UiIcon.vue'

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const props = defineProps<{
  /** Whether a worktree is currently bound to this session. */
  hasWorktree: boolean
  /** Current branch name, shown as a header inside the menu. */
  branch: string
  /** Optional status text (e.g. "clean", "2 uncommitted changes"). */
  status?: string
}>()

const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'create-worktree'): void
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'refresh'): void
  (e: 'close'): void
}>()

const menuRef = ref<HTMLElement | null>(null)

const handleClickOutside = (e: MouseEvent) => {
  if (menuRef.value && !menuRef.value.contains(e.target as Node)) {
    emit('close')
  }
}

onMounted(() => {
  // Add a tick delay so the click that opened the menu doesn't immediately close it
  setTimeout(() => document.addEventListener('click', handleClickOutside), 0)
})
onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const onCreatePr = () => {
  emit('create-pr')
  emit('close')
}
const onViewFolder = () => {
  emit('view-folder')
  emit('close')
}
const onClear = () => {
  if (
    confirm(
      'Clear the worktree binding? This removes the worktree directory and unbinds the session.',
    )
  ) {
    emit('clear')
    emit('close')
  }
}
const onRefresh = () => {
  emit('refresh')
  emit('close')
}
const onCreateWorktree = () => {
  emit('create-worktree')
  emit('close')
}
</script>

<template>
  <div
    ref="menuRef"
    class="absolute bottom-full mb-2 left-0 min-w-[200px] rounded-lg shadow-lg z-20 overflow-hidden"
    style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
  >
    <!-- Header — shows current branch and (optional) status. Gives the
         user context for what they're acting on. -->
    <div
      class="px-3 py-2 text-micro uppercase tracking-wider"
      style="
        color: var(--semantic-text-dim);
        border-bottom: 1px solid var(--color-border);
        background-color: var(--semantic-sidebar-bg);
      "
    >
      <div class="flex items-center gap-1.5">
        <UiIcon name="leaf" size-class="w-3 h-3" />
        <span style="font-family: monospace">{{ branch || 'detached' }}</span>
      </div>
      <div
        v-if="status"
        class="mt-0.5 normal-case tracking-normal"
        style="color: var(--semantic-text-muted)"
      >
        {{ status }}
      </div>
    </div>

    <!-- Worktree-bound actions — all three temporarily disabled via frontend only. -->
    <template v-if="hasWorktree">
      <button
        data-testid="worktree-menu-create-pr"
        @click="onCreatePr"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-dense flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text)"
      >
        <UiIcon name="pr" size-class="w-3 h-3" />
        <span>Create a PR</span>
      </button>
      <button
        data-testid="worktree-menu-view-folder"
        @click="onViewFolder"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-dense flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <UiIcon name="folder" size-class="w-3 h-3" />
        <span>View in folder</span>
      </button>
      <button
        data-testid="worktree-menu-clear"
        @click="onClear"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-dense flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--color-red); border-top: 1px solid var(--color-border)"
      >
        <UiIcon name="trash" size-class="w-3 h-3" />
        <span>Clear worktree</span>
      </button>
    </template>

    <!-- No-worktree actions -->
    <template v-else>
      <button
        data-testid="worktree-menu-create-worktree"
        @click="onCreateWorktree"
        class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center gap-2"
        style="color: var(--semantic-text)"
      >
        <UiIcon name="tree" size-class="w-3 h-3" />
        <span>Create worktree</span>
      </button>
      <button
        data-testid="worktree-menu-view-folder"
        @click="onViewFolder"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-dense flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <UiIcon name="folder" size-class="w-3 h-3" />
        <span>Open in folder</span>
      </button>
      <button
        data-testid="worktree-menu-refresh"
        @click="onRefresh"
        class="w-full text-left px-3 py-2 text-dense hover:opacity-80 flex items-center gap-2"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <UiIcon name="refresh" size-class="w-3 h-3" />
        <span>Refresh status</span>
      </button>
    </template>
  </div>
</template>

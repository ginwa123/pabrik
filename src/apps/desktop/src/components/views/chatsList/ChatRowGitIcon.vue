<script setup lang="ts">
import { computed } from 'vue'
import { branchStyle, branchTitle } from './chatRowHelpers'

const props = defineProps<{
  item: { id: string; git_branch?: string; git_worktree_cwd?: string }
  prStatus?: string
  prConflict: boolean
}>()

const emit = defineEmits<{
  contextmenu: [event: MouseEvent]
}>()

const style = computed(() => branchStyle(props.prStatus))
const title = computed(() => branchTitle(props.item, props.prStatus, props.prConflict))
</script>

<template>
  <span class="w-[var(--sb-mark)] shrink-0 flex items-center">
    <span
      v-if="item.git_branch && prStatus"
      class="inline-flex items-center cursor-context-menu"
      :style="style"
      :title="title + ' — right-click to open the change request'"
      :data-pr-status="prStatus || undefined"
      :data-pr-conflict="prConflict || undefined"
      data-testid="chat-git-branch"
      @contextmenu.prevent.stop="emit('contextmenu', $event)"
    >
      <svg
        class="w-3 h-3 shrink-0"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        stroke-width="2.5"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
        />
      </svg>
    </span>
  </span>
</template>

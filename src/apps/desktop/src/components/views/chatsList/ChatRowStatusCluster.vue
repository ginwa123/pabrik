<script setup lang="ts">
import UiIcon from '../../ui/UiIcon.vue'
import WorkerElapsedChip from '../../WorkerElapsedChip.vue'
import { isAwaitingReview, isReviewed, shouldShowStaleDot } from './chatRowHelpers'

defineProps<{
  item: {
    id: string
    git_branch?: string
    sub_agent_name?: string
    parent_session_id?: string
    last_human_touched_at?: string
    updated_at?: string
    relativeTime?: string
  }
  agentError: boolean
  agentErrorRetryLabel: string | null
  prConflict: boolean
  processing: boolean
}>()

const emit = defineEmits<{
  gitContextMenu: [event: MouseEvent, item: { id: string; git_branch?: string }]
}>()
</script>

<template>
  <span class="ml-2 flex items-center gap-1.5 shrink-0">
    <span
      v-if="item.sub_agent_name"
      class="text-micro"
      style="color: var(--color-violet)"
      :title="
        item.parent_session_id ? 'Sub-agent of ' + item.parent_session_id : 'Sub-agent'
      "
      ><UiIcon name="tools" size-class="w-3 h-3" /> {{ item.sub_agent_name }}</span
    >
    <span
      v-if="isAwaitingReview(item)"
      class="inline-flex items-center shrink-0"
      title="AI finished — awaiting your review"
      data-testid="chat-status-awaiting-review"
    >
      <span
        class="w-2 h-2 rounded-full"
        style="
          background-color: rgb(251, 146, 60);
          box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
          animation: chat-needs-review-pulse 2.4s ease-out 4 forwards;
        "
      />
    </span>
    <span
      v-else-if="isReviewed(item)"
      class="inline-flex items-center shrink-0 text-green-500"
      title="Reviewed"
      data-testid="chat-status-reviewed"
    >
      <svg
        class="w-3 h-3"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        stroke-width="2.5"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
    </span>
    <span
      v-if="agentError"
      class="inline-flex items-center shrink-0"
      style="color: var(--color-red)"
      :title="
        agentErrorRetryLabel
          ? `Agent error — retry ${agentErrorRetryLabel}`
          : 'Agent error'
      "
      data-testid="chat-status-agent-error"
    >
      ⚠
    </span>
    <span
      v-if="prConflict"
      class="inline-flex items-center shrink-0 cursor-context-menu"
      style="color: var(--color-red)"
      :title="'Merge conflicts — ' + (item.git_branch || '')"
      data-testid="chat-status-pr-conflict"
      @contextmenu.prevent.stop="emit('gitContextMenu', $event, item)"
    >
      <UiIcon name="alert" size-class="w-3 h-3" />
    </span>
    <span
      v-if="!processing"
      class="text-micro opacity-70 flex items-center gap-1"
    >
      <span
        v-if="shouldShowStaleDot(item)"
        class="w-1 h-1 rounded-full bg-amber-400"
        title="AI is still working — your last touch was earlier"
        data-testid="chat-stale-dot"
      />
      <span
        :title="
          item.last_human_touched_at
            ? 'Last human activity'
            : 'Last activity (never touched by you yet)'
        "
        data-testid="chat-time-pill"
        >{{ item.relativeTime || 'now' }}</span
      >
    </span>
    <WorkerElapsedChip
      v-else
      :session-id="item.id"
      test-id="chat-elapsed-chip"
      variant="text"
    />
  </span>
</template>

<style scoped>
/* Prefixed `chat-` so it cannot collide with the kanban card's
   same-shaped `needs-review-pulse` in its own scoped block. */
@keyframes chat-needs-review-pulse {
  0% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
  }
  70% {
    box-shadow: 0 0 0 12px rgba(251, 146, 60, 0);
  }
  100% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0);
  }
}

@media (prefers-reduced-motion: reduce) {
  [data-testid='chat-status-awaiting-review'] span {
    animation: none;
  }
}
</style>

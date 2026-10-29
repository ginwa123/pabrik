<script setup lang="ts">
import { useTaskDetailContext } from './kanbanTaskDetailContext'

const {
  canCommitCreate,
  canSave,
  commitTagsDraftOnSaveMouseDown,
  handleClose,
  handleRunAgent,
  handleSave,
  isCreateMode,
  isCreating,
  pendingAction,
  pendingCommitLabel,
} = useTaskDetailContext()
</script>

<template>
    <!-- Actions — sticky so the commit row stays reachable. Cancel sits
         on the far left, away from the commits; the two commits are flat
         buttons: create, then create-and-run. -->
    <div
      class="px-5 py-4 shrink-0 sticky bottom-0 z-10 flex flex-wrap items-center gap-2"
      style="border-top: 1px solid var(--color-border); background-color: var(--semantic-card-bg)"
    >
      <button
        type="button"
        @click="handleClose"
        data-testid="kanban-task-detail-cancel"
        class="px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-(--color-blue)"
        style="color: var(--semantic-text-muted)"
        title="Discard and close"
      >
        Cancel
      </button>

      <span class="flex-1"></span>

      <button
        v-if="isCreateMode"
        type="button"
        @mousedown="commitTagsDraftOnSaveMouseDown"
        @click="handleRunAgent"
        :disabled="!canCommitCreate"
        data-testid="kanban-task-detail-create-and-run"
        class="ktd-btn-quiet px-3 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-(--color-blue)"
        title="Create the task and start the agent. The title + description becomes the first user message. (Enter)"
      >
        <span
          v-if="isCreating && pendingAction !== 'create'"
          aria-hidden="true"
          class="inline-block w-3 h-3 rounded-full align-[-2px] mr-1.5"
          style="
            border: 2px solid rgba(24, 22, 22, 0.35);
            border-top-color: var(--color-bg);
            animation: ktd-spin 0.7s linear infinite;
          "
        ></span>
        <template v-if="isCreating && pendingAction !== 'create'">{{
          pendingCommitLabel
        }}</template>
        <template v-else
          ><span aria-hidden="true">▶</span
          ><span class="ml-1">Create task &amp; run agent</span></template
        >
      </button>
      <button
        v-if="isCreateMode"
        type="button"
        @mousedown="commitTagsDraftOnSaveMouseDown"
        @click="handleSave"
        :disabled="!canCommitCreate"
        data-testid="kanban-task-detail-save"
        class="ktd-btn-primary px-4 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-(--color-blue)"
      >
        {{ isCreating && pendingAction === 'create' ? pendingCommitLabel : 'Create task' }}
      </button>
      <button
        v-else
        type="button"
        @mousedown="commitTagsDraftOnSaveMouseDown"
        @click="handleSave"
        :disabled="!canSave"
        data-testid="kanban-task-detail-save"
        class="ktd-btn-primary px-4 py-1.5 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:opacity-50 hover:opacity-80 focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-(--color-blue)"
      >
        Save
      </button>
    </div>
</template>

<style scoped>
.ktd-btn-primary {
  background-color: var(--color-violet);
  color: var(--color-bg);
}


.ktd-btn-quiet {
  background-color: var(--semantic-sidebar-bg);
  border: 1px solid var(--color-border);
  color: var(--semantic-text);
}


@keyframes ktd-spin {
  to {
    transform: rotate(360deg);
  }
}


@media (prefers-reduced-motion: reduce) {
  [style*='ktd-spin'] {
    animation: none !important;
  }
}
</style>

<script setup lang="ts">
import WorkspaceMemoriesPanel from './WorkspaceMemoriesPanel.vue'

defineProps<{
  workspaceId: string
}>()
</script>

<template>
  <div class="flex h-full min-h-0 flex-col gap-4" data-testid="workspace-memories-section">
    <div>
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">Memories</h2>
      <p class="text-body mt-1" style="color: var(--semantic-text-muted)">
        Every note this workspace's agent has saved, newest first. Search by body or tag, open one
        to read it in full, or delete what is no longer true.
      </p>
    </div>

    <div class="min-h-0 flex-1">
      <WorkspaceMemoriesPanel
        :key="workspaceId"
        :workspace-id="workspaceId"
        :show-heading="false"
      />
    </div>
  </div>
</template>

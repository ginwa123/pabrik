<script setup lang="ts">
import RoutineView from '../views/RoutineView.vue'
import type { WorkspaceItem } from '../../stores/workspaces'

defineProps<{ item: WorkspaceItem; workspaceId: string }>()
</script>

<template>
  <!-- Workspace routines (Migration 084, plan
       2026-09-10-workspace-items-routines): mounted when
       item_type='routine'. The view fetches its own data via
       GET /api/workspaces/:ws/items/:item/routine. Placed after
       AgentView — same v-else-if chain position semantics (only
       one branch renders). -->
  <RoutineView :item="item" :workspace-id="workspaceId" :item-id="item.id" />
</template>

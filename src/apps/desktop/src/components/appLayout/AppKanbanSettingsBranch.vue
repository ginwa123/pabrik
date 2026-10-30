<script setup lang="ts">
import KanbanSettingsView from '../views/KanbanSettingsView.vue'

defineProps<{ itemId: string }>()
</script>

<template>
  <!-- Kanban settings page (plan: 2026-09-02-kanban-settings-as-page).
       Mounted INSIDE the <main> v-else-if chain (BEFORE KanbanView)
       so the settings page REPLACES the kanban board — no overlay.
       The :key forces a fresh mount when the user navigates from
       one kanban's settings to another's (the page re-reads
       the item id from the URL on mount). -->
  <KanbanSettingsView :item-id="itemId" />
</template>

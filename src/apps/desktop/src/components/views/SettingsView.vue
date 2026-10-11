<!--
  User settings (`/app/settings`) — the Pabrik page.

  User scope edits `~/.config/pabrik/` and applies everywhere: LLM
  profiles, general behaviour (notifications, retry, browser launch),
  MCP servers, web search providers, tool defaults, skill evals. Skills
  and Memories are workspace-scoped and live under the Workspace scope
  instead — they were removed from this sidebar because the panels always
  showed the active workspace's rows without saying so.
-->
<script setup lang="ts">
import SettingsShell from '../settings/SettingsShell.vue'
import PabrikConfigEditor from '../pabrik/PabrikConfigEditor.vue'

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const emit = defineEmits<{
  close: []
}>()
</script>

<template>
  <SettingsShell scope="user" workspace-id="">
    <template #default="{ notify }">
      <PabrikConfigEditor @notification="notify" />
    </template>
  </SettingsShell>
</template>

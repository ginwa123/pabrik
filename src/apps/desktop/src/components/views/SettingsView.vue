<!--
  User settings (`/app/settings`) — General only.

  Decision D4: General (notifications, retry delay, web launch, browser tabs)
  is the only thing that still applies to every workspace, so it is the only
  thing left here. Profiles, MCP servers, tools, skill evals and web search
  moved to Workspace settings — they were always per-workspace values, and
  hosting them under a scope whose label says "applies everywhere" made the
  label a lie. Skills and Memories were already workspace-scoped.

  The section comes from the shell's nav (`?section=`), so the editor renders
  one section with no strip of its own.
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
      <PabrikConfigEditor
        :sections="['general']"
                @notification="notify"
      />
    </template>
  </SettingsShell>
</template>

<!--
  User settings (`/app/settings`) — General and Security.

  Decision D4: General (notifications, retry delay, web launch, browser tabs)
  is the only CONFIG that still applies to every workspace, so it is the only
  config section left here. Profiles, MCP servers, tools, skill evals and web
  search moved to Workspace settings — they were always per-workspace values.

  Security is here for the same reason: `users.password_hash` belongs to the
  account, not to one workspace. The section comes from the shell's nav
  (`?section=`), so each view renders without a strip of its own.
-->
<script setup lang="ts">
import SettingsShell from '../settings/SettingsShell.vue'
import PabrikConfigEditor from '../pabrik/PabrikConfigEditor.vue'
import AccountSecuritySection from '../pabrik/AccountSecuritySection.vue'
import AppearanceSection from '../settings/AppearanceSection.vue'

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const emit = defineEmits<{
  close: []
}>()
</script>

<template>
  <SettingsShell scope="user" workspace-id="">
    <template #default="{ section, notify }">
      <AccountSecuritySection v-if="section === 'security'" @notification="notify" />
      <AppearanceSection v-else-if="section === 'appearance'" />
      <PabrikConfigEditor v-else :sections="['general']" @notification="notify" />
    </template>
  </SettingsShell>
</template>

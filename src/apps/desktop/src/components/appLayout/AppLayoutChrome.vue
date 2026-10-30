<script setup lang="ts">
import TerminalFooter from '../shell/TerminalFooter.vue'
import SettingsView from '../views/SettingsView.vue'
import WorkspaceSettingsView from '../views/WorkspaceSettingsView.vue'
import NotificationContainer from '../shell/NotificationContainer.vue'
import SseStatusBadge from '../shell/SseStatusBadge.vue'
import type { Workspace } from '../../stores/workspaces'

defineProps<{ workspaces: Workspace[]; activeWorkspaceId: string; cwd: string; view: string }>()
</script>

<template>
  <!-- The window-level terminal footer: a strip along the bottom of the
       app, outside every column, carrying the launcher for the live
       shells (the right sidebar's Terminal tab stays where it is). -->
  <TerminalFooter :workspaces="workspaces" :active-workspace-id="activeWorkspaceId" :cwd="cwd" />

  <!-- Settings page -->
  <SettingsView v-if="view === 'settings'" />

  <!-- Workspace settings page (/app/:workspaceId/settings). Mounted as a
       sibling of <main> like <SettingsView>, not inside the view chain:
       which settings SECTION is open is `?section=`, owned by the view. -->
  <WorkspaceSettingsView v-else-if="view === 'workspace-settings'" />

  <!-- Global error notification stack -->
  <NotificationContainer />

  <!-- Global SSE connection status pill. Renders nothing while the
       connection is healthy (state === 'open'); surfaces a small
       "Connecting…" / "Reconnecting…" / "Connection lost" pill in
       the top-right corner when the bus is in a degraded state.
       Fixed-positioned so it stays visible regardless of which
       view (chat / kanban / settings / workspace) is active.
       `pointer-events-none` keeps the pill visible WITHOUT
       capturing clicks — the pill overlaps the top-right of every
       view's chrome (in the kanban 3-column layout it sits on top
       of ChatView's ✕ close button; in design mode it sits on top
       of any future top-right toolbar). The pill is purely
       informational (no controls inside), so passing the click
       through is the right behavior. -->
  <div class="fixed top-3 right-3 z-50 pointer-events-none" data-testid="sse-status-badge-container">
    <SseStatusBadge />
  </div>
</template>

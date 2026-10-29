<!--
  SettingsShell — the one chrome for both settings scopes.

  User scope (`/app/settings`) edits `~/.config/pabrik/` (agents, MCP,
  tools, general, web search, evals). Workspace scope
  (`/app/:workspaceId/settings`) edits one workspace (overview, secrets,
  skills, memories). The path IS the scope — no `?scope=` param — and the
  open section rides in `?section=` via `useSettingsSection`, so refresh,
  Back/Forward and shared links restore the view (repo rule: every view
  switch syncs the browser URL).

  Content stays with the callers: the shell renders the scope switcher +
  sidebar + toast and hands the active section + a `notify` function to
  its default slot.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSettingsSection } from '../../composables/useSettingsSection'
import { WORKSPACE_AGENT_SECTIONS } from '../../helpers/configSource'
import { resolveWorkspaceId } from '../../helpers/workspaceScope'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

export type SettingsScope = 'user' | 'workspace'

export interface SettingsSectionItem {
  id: string
  label: string
  icon: UiIconName
  /**    * Heading this item sits under. A heading is rendered only where the group CHANGES, so the first
   * group needs no separate label above the scope label the sidebar already shows. */
  group?: string
}

const USER_SECTIONS: readonly SettingsSectionItem[] = [
  // Decision D4: General is the only CONFIG left at user level — the rest moved to Workspace
  // settings. Security sits here too because an account's password is not a workspace value.
  // Appearance is a per-browser UI preference, which also belongs to the user, not a workspace.
  { id: 'general', label: 'General', icon: 'settings' },
  { id: 'appearance', label: 'Appearance', icon: 'palette' },
  { id: 'security', label: 'Security', icon: 'lock' },
]

/**  * Presentation for each moved config section. A `Record` keyed by the section ids, not a parallel
 * hand-written list: adding an id to `WORKSPACE_AGENT_SECTIONS` without a label here is then a TYPE
 * error, which is what stops the nav and the workspace view drifting into a dead nav item. */
const AGENT_SECTION_META: Record<
  (typeof WORKSPACE_AGENT_SECTIONS)[number],
  { label: string; icon: UiIconName }
> = {
  agents: { label: 'Agents', icon: 'atom' },
  mcp: { label: 'MCP Servers', icon: 'globe' },
  tools: { label: 'Tools', icon: 'tools' },
  evals: { label: 'Skill Evals', icon: 'sparkle' },
}

const WORKSPACE_SECTIONS: readonly SettingsSectionItem[] = [
  { id: 'overview', label: 'Overview', icon: 'cards', group: 'Workspace' },
  { id: 'secrets', label: 'Secrets', icon: 'key', group: 'Workspace' },
  { id: 'skills', label: 'Skills', icon: 'books', group: 'Workspace' },
  { id: 'memories', label: 'Memories', icon: 'brain', group: 'Workspace' },
  // The sections that moved here (Migration 105 + `PabrikConfigEditor`): they edit THIS workspace's
  // config overlay, which the backend merges over the user-level config, so a workspace that
  // overrides nothing still behaves exactly as it did before they existed.
  ...WORKSPACE_AGENT_SECTIONS.map((id) => ({ id, ...AGENT_SECTION_META[id], group: 'Agent' })),
]

const USER_STORAGE_KEY = 'settings-shell-user-section'
const WORKSPACE_STORAGE_KEY = 'settings-shell-workspace-section'

const props = defineProps<{
  scope: SettingsScope
  /** Route workspace id. Empty in user scope. */
  workspaceId: string
}>()

const router = (() => {
  try {
    return useRouter()
  } catch (e) {
    // Router-less mount (unit tests): navigation becomes a no-op. The section state still works
    // through the local-ref fallback in `useSettingsSection`, so the null here can never surface as
    // a wrong section — only as a button that does nothing in tests.
    console.warn('[settings-shell] no router, navigation disabled', e)
    return null
  }
})()
const workspacesStore = useWorkspacesStore()

const sections = computed<readonly SettingsSectionItem[]>(() =>
  props.scope === 'user' ? USER_SECTIONS : WORKSPACE_SECTIONS,
)

const { section, select } = useSettingsSection({
  sections: sections.value.map((s) => s.id),
  defaultSection: sections.value[0]?.id ?? 'pabrik',
  storageKey: props.scope === 'user' ? USER_STORAGE_KEY : WORKSPACE_STORAGE_KEY,
})

const scopeLabel = computed(() =>
  props.scope === 'user' ? 'User — applies everywhere' : 'Workspace — this workspace only',
)

const workspaceOptions = computed(() =>
  workspacesStore.workspaces.map((w) => ({ id: w.id, name: w.name })),
)

/** The workspace this settings surface is ABOUT: the one in the URL, else the one the app is
 * actually in. `workspaceOptions[0]` is NOT that workspace. */
const inScopeWorkspaceId = computed(() =>
  resolveWorkspaceId(props.workspaceId, workspacesStore.activeWorkspace?.id),
)

function goUser(): void {
  if (props.scope === 'user' || !router) return
  void router.push({ path: '/app/settings' })
}

function goWorkspace(id: string): void {
  if (!id || !router) return
  if (props.scope === 'workspace' && id === props.workspaceId) return
  void router.push({ path: `/app/${id}/settings` })
}

/**  * The Workspace tab's target. The in-scope workspace wins; only a cold boot with neither a URL
 * workspace nor an active one falls back to the first listed row, because the tab has to resolve to
 * something. */
function goWorkspaceScope(): void {
  goWorkspace(inScopeWorkspaceId.value || workspaceOptions.value[0]?.id || '')
}

function goBack(): void {
  if (!router) return
  router.back()
}

// Notification toast state. Section content reports through the `notify`
// slot prop; the shell owns the timer so both scopes share one toast.
const notification = ref<{ message: string; type: 'success' | 'error' } | null>(null)

function notify(message: string, type: 'success' | 'error'): void {
  notification.value = { message, type }
  setTimeout(() => {
    notification.value = null
  }, 3000)
}
</script>

<template>
  <!-- Fullscreen Settings Overlay -->
  <div
    class="fixed inset-0 z-50 flex"
    style="background-color: var(--semantic-content-bg)"
    data-testid="settings-shell"
    :data-scope="props.scope"
  >
    <!-- Settings Sidebar -->
    <div
      class="h-full flex flex-col shrink-0"
      style="
        width: 240px;
        background-color: var(--semantic-sidebar-bg);
        border-right: 1px solid var(--color-border);
      "
    >
      <!-- Settings Header -->
      <div
        class="h-14 flex items-center px-4 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <button
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 mr-3"
          style="color: var(--semantic-text-muted)"
          title="Back"
          data-testid="settings-back"
          @click="goBack"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>
        <h1 class="text-title-sm font-semibold" style="color: var(--semantic-text)">Settings</h1>
      </div>

      <!-- Scope switcher -->
      <div class="px-3 pt-3 shrink-0">
        <div
          class="flex rounded-lg p-0.5"
          role="tablist"
          aria-label="Settings scope"
          data-testid="settings-scope-switch"
          style="
            background-color: var(--semantic-content-bg);
            border: 1px solid var(--color-border);
          "
        >
          <button
            type="button"
            role="tab"
            :aria-selected="props.scope === 'user'"
            data-testid="settings-scope-user"
            class="flex-1 px-2 py-1.5 rounded-md text-dense font-medium transition-all duration-200"
            :style="
              props.scope === 'user'
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="goUser"
          >
            User
          </button>
          <button
            type="button"
            role="tab"
            :aria-selected="props.scope === 'workspace'"
            data-testid="settings-scope-workspace"
            class="flex-1 px-2 py-1.5 rounded-md text-dense font-medium transition-all duration-200"
            :style="
              props.scope === 'workspace'
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="goWorkspaceScope()"
          >
            Workspace
          </button>
        </div>
        <!-- Workspace context is the URL (`/app/:workspaceId/settings`): no
          label or picker here. Switching workspaces is the sidebar's job,
          not settings'. -->
      </div>

      <!-- Settings Menu -->
      <nav class="flex-1 py-4 px-3 overflow-y-auto" aria-label="Settings sections">
        <p
          class="px-3 mb-2 text-dense uppercase tracking-wide"
          style="color: var(--semantic-text-muted)"
          data-testid="settings-scope-label"
        >
          {{ scopeLabel }}
        </p>
        <template v-for="(item, index) in sections" :key="item.id">
          <p
            v-if="index > 0 && item.group !== sections[index - 1]?.group"
            class="px-3 mt-4 mb-2 text-dense uppercase tracking-wide"
            style="color: var(--semantic-text-muted)"
            :data-testid="`settings-nav-group-${item.group ?? 'other'}`"
          >
            {{ item.group }}
          </p>
          <button
            :data-testid="`settings-nav-${item.id}`"
            :data-tab-id="item.id"
            :data-active="section === item.id ? 'true' : 'false'"
            role="tab"
            :aria-selected="section === item.id"
            class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-body font-medium transition-all duration-200 mb-1"
            :style="
              section === item.id
                ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
            @click="select(item.id)"
          >
            <UiIcon :name="item.icon" size-class="w-4.5 h-4.5" />
            <span>{{ item.label }}</span>
          </button>
        </template>
      </nav>
    </div>

    <!-- Settings Content -->
    <main class="flex-1 flex flex-col overflow-hidden">
      <div class="flex-1 overflow-y-auto p-6">
        <slot :section="section" :notify="notify" />
      </div>
    </main>

    <!-- Notification Toast -->
    <div
      v-if="notification"
      class="fixed bottom-6 right-6 px-4 py-3 rounded-lg shadow-lg z-50"
      data-testid="settings-notification"
      :style="
        notification.type === 'success'
          ? 'background-color: var(--color-green); color: white;'
          : 'background-color: var(--color-red); color: white;'
      "
    >
      {{ notification.message }}
    </div>
  </div>
</template>

<!--
  Workspace settings (`/app/:workspaceId/settings`) — one workspace's
  Overview, Secrets, Skills, Memories, and the config sections that moved
  here: Profiles, MCP Servers, Tools and Skill Evals.

  The config sections edit THIS workspace's overlay
  (`/api/workspaces/:id/config`), which the backend merges over the
  user-level config. A workspace that has overridden nothing therefore
  behaves exactly as it did before they existed.

  Skills are rows scoped to one workspace (`GET
  /workspaces/:id/skills`), so the panel binds the route workspace — not
  the active workspace from the store, which is what the old global
  Skills tab showed without saying so. Memories are per-item directories
  (`<item-path>/.pabrik/memories/`), picked per item in the section.
  Secrets never leave this scope: they are invisible under User scope.
-->
<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { onBeforeRouteUpdate, useRoute } from 'vue-router'
import { useSecretsStore } from '../../stores/secrets'
import { useWorkspacesStore } from '../../stores/workspaces'
import SettingsShell from '../settings/SettingsShell.vue'
import PabrikConfigEditor from '../pabrik/PabrikConfigEditor.vue'
import { WORKSPACE_AGENT_SECTIONS, workspaceConfigSource } from '../../helpers/configSource'
import SecretsSection from '../workspace/SecretsSection.vue'
import SkillsSettings from '../preview/SkillsSettings.vue'
import WorkspaceMemoriesSection from '../workspace/WorkspaceMemoriesSection.vue'

const route = useRoute()
const secretsStore = useSecretsStore()
const workspacesStore = useWorkspacesStore()

/**  * The workspace this settings page belongs to. Read from the route param, not from `parseAppPath`:
 * `/app/{ws}/settings` is not one of the shapes `helpers/appUrl.ts` knows. Falls back to the active
 * workspace so the page still works if it is ever mounted without the param. */
const workspaceId = computed<string>(() => {
  const fromPath = route?.params?.workspaceId
  if (typeof fromPath === 'string' && fromPath.length > 0) return fromPath
  return workspacesStore.activeWorkspace?.id ?? ''
})

const workspaceName = computed<string>(() => {
  if (workspacesStore.activeWorkspace?.id === workspaceId.value) {
    return workspacesStore.activeWorkspace.name
  }
  return workspaceId.value || 'this workspace'
})

/**  * The four sections that moved here from the User-scope Pabrik page. They render through ONE
 * long-lived `PabrikConfigEditor` rather than one instance per section: switching between them must
 * not remount the editor, or every unsaved edit would be thrown away by a nav click. */
const isAgentSection = computed<boolean>(() =>
  (WORKSPACE_AGENT_SECTIONS as readonly string[]).includes(route?.params ? sectionFromRoute() : ''),
)

function sectionFromRoute(): string {
  const raw = route?.query?.section
  const value = Array.isArray(raw) ? raw[0] : raw
  return typeof value === 'string' ? value : ''
}

/** The source is rebuilt per workspace; the editor is keyed on the id so a
 * workspace switch remounts it rather than editing the previous workspace. */
const agentSource = computed(() => workspaceConfigSource(workspaceId.value))

const itemCount = computed<number>(() => {
  const ws = workspacesStore.activeWorkspace
  if (!ws || ws.id !== workspaceId.value) return 0
  return ws.items?.length ?? 0
})

// Fetch per workspace, and only when there IS one. `reset()` on every id change is what stops one
// workspace's secrets (or its failure banner) from being painted under another workspace's header.

// A navigation guard, not a `watch()`: new watchers are banned (local/no-watch) — reacting must
// live in the event handler that caused the change, and a workspace switch IS a navigation.
function loadSecretsFor(id: string): void {
  secretsStore.reset()
  if (id) void secretsStore.fetchSecrets(id)
}

onMounted(() => {
  loadSecretsFor(workspaceId.value)
})

onBeforeRouteUpdate((to) => {
  const raw = to.params.workspaceId
  const next = typeof raw === 'string' ? raw : ''
  // Query-only navigations (e.g. `?section=` tab switches) reuse this
  // component too — refetching there would wipe the list mid-click.
  if (next === workspaceId.value) return
  loadSecretsFor(next)
})

/**  * Hand a new credential to the store, which forwards it to the API and keeps nothing. This handler
 * deliberately does not stash the payload on any reactive state — the emit already delivered it and
 * the component has already cleared its inputs. */
async function handleAdd(payload: { name: string; value: string }): Promise<void> {
  if (!workspaceId.value) return
  await secretsStore.createSecret(workspaceId.value, payload.name, payload.value)
}

async function handleRotate(payload: { id: string; name: string; value: string }): Promise<void> {
  if (!workspaceId.value) return
  await secretsStore.rotateSecret(workspaceId.value, payload.id, payload.value)
}

/** The section emits the NAME; the store needs the id, so match on it. */
async function handleDelete(name: string): Promise<void> {
  const target = secretsStore.secrets.find((s) => s.name === name)
  if (!target || !workspaceId.value) return
  await secretsStore.deleteSecret(workspaceId.value, target.id)
}

function handleRetry(): void {
  if (workspaceId.value) void secretsStore.fetchSecrets(workspaceId.value)
}
</script>

<template>
  <div class="h-full overflow-y-auto" data-testid="workspace-settings-view">
    <SettingsShell scope="workspace" :workspace-id="workspaceId">
      <template #default="{ section, notify }">
        <div v-if="section === 'overview'" class="mx-auto w-full max-w-3xl space-y-6">
          <header class="space-y-1">
            <h1 class="text-title-lg font-semibold" style="color: var(--semantic-text)">
              Workspace settings
            </h1>
            <p class="text-dense" style="color: var(--semantic-text-muted)">
              Configuration for {{ workspaceName }}.
            </p>
          </header>

          <section
            data-testid="overview-section"
            role="tabpanel"
            class="px-4 py-4 rounded-md space-y-2"
            style="
              background-color: var(--semantic-content-bg);
              border: 1px solid var(--color-border);
            "
          >
            <div class="flex items-baseline justify-between gap-4">
              <span class="text-dense" style="color: var(--semantic-text-muted)">Workspace</span>
              <span class="text-body font-mono" style="color: var(--semantic-text)">{{
                workspaceName
              }}</span>
            </div>
            <div class="flex items-baseline justify-between gap-4">
              <span class="text-dense" style="color: var(--semantic-text-muted)">Workspace ID</span>
              <span class="text-body font-mono" style="color: var(--semantic-text)">{{
                workspaceId || '—'
              }}</span>
            </div>
            <div class="flex items-baseline justify-between gap-4">
              <span class="text-dense" style="color: var(--semantic-text-muted)">Items</span>
              <span class="text-body font-mono" style="color: var(--semantic-text)">{{
                itemCount
              }}</span>
            </div>
          </section>
        </div>

        <div v-else-if="section === 'secrets'" class="mx-auto w-full max-w-3xl">
          <section data-testid="secrets-section" role="tabpanel">
            <SecretsSection
              :secrets="secretsStore.secrets"
              :loading="secretsStore.loading"
              :loaded="secretsStore.loaded"
              :error="secretsStore.error"
              :saving="secretsStore.saving"
              @add="handleAdd"
              @rotate="handleRotate"
              @delete="handleDelete"
              @retry="handleRetry"
            />
          </section>
        </div>

        <div v-else-if="section === 'skills'" class="h-full">
          <section data-testid="skills-section" role="tabpanel" class="h-full">
            <SkillsSettings :workspace-id="workspaceId" @notification="notify" />
          </section>
        </div>

        <div v-else-if="section === 'memories'" class="h-full">
          <section data-testid="memories-section" role="tabpanel" class="h-full">
            <WorkspaceMemoriesSection :workspace-id="workspaceId" />
          </section>
        </div>

        <!-- Profiles / MCP Servers / Tools / Skill Evals, in this workspace's
             scope. `:key` on the workspace id, NOT on the section: a section
             switch must keep the same editor instance (unsaved edits), while a
             workspace switch must not (they belong to the other workspace). -->
        <div v-else-if="isAgentSection" class="h-full">
          <section :data-testid="`${section}-section`" role="tabpanel" class="h-full">
            <PabrikConfigEditor
              :key="workspaceId"
              :source="agentSource"
              :sections="WORKSPACE_AGENT_SECTIONS"
                            @notification="notify"
            />
          </section>
        </div>
      </template>
    </SettingsShell>
  </div>
</template>

<!--
  KanbanSettingsView — dedicated full-page route for per-board kanban
  settings. Replaces KanbanSettingsDialog (the centered modal that
  used to pop up when the user clicked the board header's Settings
  button).

  URL: /app/kanban/:itemId/settings (path-based vue-router route).
  The page reads itemId from route.params and derives workspaceId
  from the store by walking workspaces (itemId is globally unique).

  Layout (single column, no sidebar — the page REPLACES the kanban
  board entirely, not overlays it):
    1. Top header bar — back button + "Kanban Settings" title +
       kanban name (inline rename) all on one row.
    2. Tab strip below the header — "Columns" / "Agent"
       (Local Memories is now embedded inside the Agent tab when
       item.path is set, instead of a standalone tab).
    3. Content area (full width):
       - Columns tab: add-column inline form + columns list with
         per-row edit/delete + copy-spec footer.
       - Agent tab: AgentView with Tools on left + Knowledge/System Prompt on right
         (Knowledge moved from left to right per arrow), Local Memories
         in left sidebar alongside Tools (moved from bottom bar per arrow)
         via left-extra slot (WorkspaceItemMemoriesView when item.path is truthy).

  Empty / not-found states render centered hints with friendly
  messages instead of the columns UI.

  Plan: docs/superpowers/plans/2026-09-02-kanban-settings-as-page.md
-->
<script setup lang="ts">
import { computed, onMounted, onUpdated, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import KanbanColumnEditor from '../kanban/KanbanColumnEditor.vue'
import InlineEditableText from '../preview/InlineEditableText.vue'
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
import AgentView from './AgentView.vue'
import type { AgnosticKnowledgeRow, AgnosticSystemPromptRow } from './AgentView.vue'
import AgentKnowledgeDialog from '../dialogs/AgentKnowledgeDialog.vue'
import AgentKnowledgeDetailDialog from '../dialogs/AgentKnowledgeDetailDialog.vue'
import AgentSystemPromptDialog from '../dialogs/AgentSystemPromptDialog.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { buildAppUrl } from '../../helpers/appUrl'
import * as api from '../../api'
import UiIcon from '../ui/UiIcon.vue'
import { buildToggle } from '../../stores/agentToolToggle'

type SettingsMode = 'columns' | 'agent'

const VALID_TABS: readonly SettingsMode[] = ['columns', 'agent']

const route = useRoute()
const router = useRouter()
const workspacesStore = useWorkspacesStore()

// ─── Emits ─────────────────────────────────────────────────────────────────
const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [payload: { columnId: string; name: string; description: string }]
  deleteColumn: [columnId: string]
  renameItem: [name: string]
  copySpec: []
}>()

// ─── State ──────────────────────────────────────────────────────────────────
// Active tab is URL-backed (?section=columns|agent). `section` is used
// instead of `tab` because `?tab=<tabId>` is owned by the browser-style
// tab mode (helpers/tabTarget.ts, stores/tabs.ts) — sharing the key meant
// a URL like `?tab=tab_xxx` fell through to 'columns' and clicking Agent
// clobbered the browser tab ID, so the tab store snapped the URL back
// and the Agent tab looked unclickable. Default to 'columns' when the
// query is missing or unknown — keeps the URL clean (no ?section=columns
// in the default state).
// Legacy `?tab=agent|tools|knowledge|memories|columns` (pre tab-mode)
// links still land correctly; any other `?tab=` value (notably the
// `tab_<id>` browser IDs) is ignored so the browser tab stays intact.
const settingsMode = computed<SettingsMode>({
  get: () => {
    const readSection = (v: unknown): SettingsMode | null => {
      const s = Array.isArray(v) ? v[0] : v
      if (s === 'tools' || s === 'knowledge' || s === 'memories') return 'agent'
      return (VALID_TABS as readonly string[]).includes(s ?? '') ? (s as SettingsMode) : null
    }
    // Canonical param first.
    const fromSection = readSection(route.query.section)
    if (fromSection) return fromSection
    // Legacy fallback — only for known settings values, never for
    // browser tab IDs.
    const fromLegacyTab = readSection(route.query.tab)
    if (fromLegacyTab) return fromLegacyTab
    return 'columns'
  },
  set: (next) => {
    const rest = { ...route.query }
    if (next === 'columns') {
      // Default tab — strip from URL to keep it tidy. Never touch
      // `tab` (the browser tab ID owned by the tab store).
      delete rest.section
      delete rest.tab
      // Preserve a browser tab ID if one is present: the legacy `tab`
      // key may hold either a settings value or a browser ID — only
      // restore it when it looks like a browser ID.
      const rawTab = route.query.tab
      const s = Array.isArray(rawTab) ? rawTab[0] : rawTab
      if (typeof s === 'string' && s.startsWith('tab_')) rest.tab = s
    } else {
      rest.section = next
      // If the legacy `tab` key holds a settings value, drop it so the
      // URL doesn't carry two sources of truth. A browser tab ID stays.
      const rawTab = route.query.tab
      const s = Array.isArray(rawTab) ? rawTab[0] : rawTab
      if (typeof s !== 'string' || !s.startsWith('tab_')) delete rest.tab
    }
    void router.replace({ query: rest })
  },
})

// Add-column inline form state
const newColumnName = ref('')
const newColumnDescription = ref('')

// Per-row rename/delete editor (lifted from KanbanSettingsDialog's KanbanColumnEditor). Owns its
// own state so the page can open the editor independently of any other KanbanColumnEditor mounted
// by AppLayout for the ⋮ menu flow.
type SettingsEditorMode = 'rename' | 'delete'
const showSettingsEditor = ref(false)
const settingsEditorMode = ref<SettingsEditorMode>('rename')
const settingsEditorTargetId = ref<string | null>(null)
const settingsEditorTargetName = ref('')
const settingsEditorTargetDescription = ref('')

// ─── Computed ──────────────────────────────────────────────────────────────
// itemId comes from route.params (path). May be empty if the URL is
// malformed — defensive: render the "no kanban selected" hint.
const itemId = computed<string>(() => {
  const raw = route.params.itemId
  return typeof raw === 'string' ? raw : ''
})

// Look up the kanban WorkspaceItem across all workspaces. itemId is globally unique
// (workspace_items.id is the PK), so we don't need to filter by workspaceId first — but we still
// derive workspaceId below for the back navigation round-trip.
const item = computed(() => {
  const id = itemId.value
  if (!id) return null
  for (const ws of workspacesStore.workspaces) {
    const found = ws.items.find((i) => i.id === id)
    if (found) return found
  }
  return null
})

// Derive workspaceId by walking the store looking for the workspace that owns the current item.
// Returns '' if the item isn't found (defensive — goBack uses this to round-trip back to the kanban
// view; if we can't find the owning workspace, fall back to /app).
const workspaceId = computed<string>(() => {
  const id = itemId.value
  if (!id) return ''
  for (const ws of workspacesStore.workspaces) {
    if (ws.items.some((i) => i.id === id)) return ws.id
  }
  return ''
})

const notFound = computed(() => !!itemId.value && !item.value)
const emptyHint = computed(() => !itemId.value)

// ─── Kanban Agent (reuses AgentView) ──────────────────────────────────────── Kanban boards reuse
// the same Knowledge + Tools + System Prompt UI as `item_type='agent'` — AgentView is now agnostic
// (accepts both AgentKnowledgeRow and AgentKanbanKnowledgeRow via union).
// The parent (this view) owns the data + API calls; AgentView is a dumb presentational component
// that emits intents.
const kanbanKnowledge = ref<api.AgentKanbanKnowledgeRow[]>([])
const kanbanTools = ref<string[]>([])
const kanbanSystemPrompts = ref<api.AgentKanbanSystemPromptRow[]>([])

// True while `loadKanbanAgent` is in flight — AgentView's knowledge and system-prompt panels gate
// their skeletons on this. Without it they render "No knowledge files yet." during the fetch, which
// is a false statement about the board's data.
const kanbanAgentLoading = ref(false)

async function loadKanbanAgent() {
  const id = item.value?.id
  const wsId = workspaceId.value
  if (!id || !wsId) return
  kanbanAgentLoading.value = true
  try {
    const data = await api.getAgentKanban(wsId, id)
    if (data) {
      kanbanKnowledge.value = data.knowledges
      kanbanTools.value = data.tools
      kanbanSystemPrompts.value = data.system_prompts
    } else {
      kanbanKnowledge.value = []
      kanbanTools.value = []
      kanbanSystemPrompts.value = []
    }
  } catch (e) {
    console.error('[KanbanSettingsView] failed to load kanban agent:', e)
  } finally {
    // Cleared on BOTH paths so a failed fetch cannot park the skeleton.
    kanbanAgentLoading.value = false
  }
}

// Reload the agent panel when the resolved item changes: mount covers
// the initial load, prev-id guard on update covers item switches.
const prevAgentItemId = ref(item.value?.id ?? '')
onMounted(() => {
  prevAgentItemId.value = item.value?.id ?? ''
  if (item.value?.id) void loadKanbanAgent()
})
onUpdated(() => {
  const rowId = item.value?.id ?? ''
  if (rowId !== prevAgentItemId.value) {
    prevAgentItemId.value = rowId
    if (rowId) void loadKanbanAgent()
  }
})

// ─── AgentView dialog state (mirrors AppLayout's agent dialogs) ─────────────
const kanbanKnowledgeDialogOpen = ref(false)
const kanbanKnowledgeError = ref<string | null>(null)
const kanbanKnowledgeBusy = ref(false)

const kanbanKnowledgeDetailOpen = ref(false)
const kanbanKnowledgeDetailRow = ref<api.AgentKanbanKnowledgeRow | null>(null)
const kanbanKnowledgeDetailBusy = ref(false)
const kanbanKnowledgeDetailError = ref<string | null>(null)

const kanbanSystemPromptDialogOpen = ref(false)
const kanbanSystemPromptRow = ref<api.AgentKanbanSystemPromptRow | null>(null)
const kanbanSystemPromptBusy = ref(false)
const kanbanSystemPromptError = ref<string | null>(null)

function tryParseErrorBody(body: string): string | null {
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') return obj.error
    return null
  } catch {
    return null
  }
}

function handleKanbanAddKnowledge() {
  kanbanKnowledgeError.value = null
  kanbanKnowledgeDialogOpen.value = true
}

function closeKanbanKnowledgeDialog() {
  kanbanKnowledgeDialogOpen.value = false
  kanbanKnowledgeError.value = null
}

async function handleKanbanKnowledgeCreate(filePath: string, label: string, content: string) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  kanbanKnowledgeBusy.value = true
  kanbanKnowledgeError.value = null
  try {
    const newRow = await api.addAgentKanbanKnowledge(kanbanId, filePath, label, content)
    kanbanKnowledge.value = [...kanbanKnowledge.value, newRow]
    closeKanbanKnowledgeDialog()
  } catch (e) {
    kanbanKnowledgeError.value = e instanceof Error ? e.message : 'Failed to add knowledge'
  } finally {
    kanbanKnowledgeBusy.value = false
  }
}

function handleKanbanEditKnowledge(row: AgnosticKnowledgeRow) {
  // AgentView emits AgnosticKnowledgeRow — for kanban we know it's a kanban row
  kanbanKnowledgeDetailRow.value = row as api.AgentKanbanKnowledgeRow
  kanbanKnowledgeDetailError.value = null
  kanbanKnowledgeDetailOpen.value = true
}

function closeKanbanKnowledgeDetailDialog() {
  kanbanKnowledgeDetailOpen.value = false
  kanbanKnowledgeDetailError.value = null
}

async function handleKanbanKnowledgeSave(
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  kanbanKnowledgeDetailBusy.value = true
  kanbanKnowledgeDetailError.value = null
  try {
    const updated = await api.updateAgentKanbanKnowledge(kanbanId, knowledgeId, updates)
    kanbanKnowledge.value = kanbanKnowledge.value.map((k) => (k.id === knowledgeId ? updated : k))
    closeKanbanKnowledgeDetailDialog()
  } catch (e) {
    kanbanKnowledgeDetailError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update knowledge'
  } finally {
    kanbanKnowledgeDetailBusy.value = false
  }
}

async function handleKanbanRemoveKnowledge(knowledgeId: string) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  const previous = kanbanKnowledge.value
  kanbanKnowledge.value = previous.filter((k) => k.id !== knowledgeId)
  try {
    await api.deleteAgentKanbanKnowledge(kanbanId, knowledgeId)
  } catch (e) {
    kanbanKnowledge.value = previous
    console.error('[KanbanSettingsView] failed to remove knowledge:', e)
  }
}

function handleKanbanAddSystemPrompt() {
  kanbanSystemPromptRow.value = null
  kanbanSystemPromptError.value = null
  kanbanSystemPromptDialogOpen.value = true
}

function handleKanbanEditSystemPrompt(row: AgnosticSystemPromptRow) {
  kanbanSystemPromptRow.value = row as api.AgentKanbanSystemPromptRow
  kanbanSystemPromptError.value = null
  kanbanSystemPromptDialogOpen.value = true
}

function closeKanbanSystemPromptDialog() {
  kanbanSystemPromptDialogOpen.value = false
  kanbanSystemPromptError.value = null
}

async function handleKanbanSystemPromptCreate(title: string, content: string) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  kanbanSystemPromptBusy.value = true
  kanbanSystemPromptError.value = null
  try {
    const newRow = await api.addAgentKanbanSystemPrompt(kanbanId, title, content)
    kanbanSystemPrompts.value = [...kanbanSystemPrompts.value, newRow]
    closeKanbanSystemPromptDialog()
  } catch (e) {
    kanbanSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to add system prompt'
  } finally {
    kanbanSystemPromptBusy.value = false
  }
}

async function handleKanbanSystemPromptSave(
  promptId: string,
  updates: { title: string; content: string },
) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  kanbanSystemPromptBusy.value = true
  kanbanSystemPromptError.value = null
  try {
    const updated = await api.updateAgentKanbanSystemPrompt(kanbanId, promptId, updates)
    kanbanSystemPrompts.value = kanbanSystemPrompts.value.map((p) =>
      p.id === promptId ? updated : p,
    )
    closeKanbanSystemPromptDialog()
  } catch (e) {
    kanbanSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update system prompt'
  } finally {
    kanbanSystemPromptBusy.value = false
  }
}

async function handleKanbanRemoveSystemPrompt(promptId: string) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  const previous = kanbanSystemPrompts.value
  kanbanSystemPrompts.value = previous.filter((p) => p.id !== promptId)
  try {
    await api.deleteAgentKanbanSystemPrompt(kanbanId, promptId)
  } catch (e) {
    kanbanSystemPrompts.value = previous
    console.error('[KanbanSettingsView] failed to remove system prompt:', e)
  }
}

async function handleKanbanToggleTool(toolName: string, enabled: boolean) {
  const kanbanId = item.value?.id
  if (!kanbanId) return
  const { nextLocal, serverPromise } = buildToggle(kanbanTools.value, toolName, enabled, kanbanId, {
    enableAgentTool: api.enableAgentKanbanTool,
    disableAgentTool: api.disableAgentKanbanTool,
    refetchAgentTools: async (id) => {
      const data = await api.getAgentKanban(workspaceId.value, id)
      return data?.tools ?? []
    },
  })
  kanbanTools.value = nextLocal
  const out = await serverPromise
  if ('error' in out) {
    kanbanTools.value = enabled
      ? kanbanTools.value.filter((n) => n !== toolName)
      : [...kanbanTools.value, toolName]
    console.error('[KanbanSettingsView] toggle tool failed:', out.error)
    return
  }
  kanbanTools.value = out.canonical
  // If this was the first enable on an unconfigured board, the backend
  // auto-seeded the row — reload the full bundle so knowledge/system
  // prompts become available without a manual refresh.
  if (kanbanKnowledge.value.length === 0 && kanbanSystemPrompts.value.length === 0) {
    void loadKanbanAgent()
  }
}

async function handleKanbanToggleToolsBulk(toolNames: string[], enabled: boolean) {
  const kanbanId = item.value?.id
  if (!kanbanId || toolNames.length === 0) return
  const set = new Set(kanbanTools.value)
  for (const n of toolNames) {
    if (enabled) set.add(n)
    else set.delete(n)
  }
  kanbanTools.value = Array.from(set)
  try {
    const ops = toolNames.map(async (n) => {
      try {
        if (enabled) await api.enableAgentKanbanTool(kanbanId, n)
        else await api.disableAgentKanbanTool(kanbanId, n)
        return { name: n, ok: true as const }
      } catch (e) {
        return { name: n, ok: false as const, error: e }
      }
    })
    const results = await Promise.all(ops)
    const failures = results.filter((r) => !r.ok)
    if (failures.length > 0)
      console.error('[KanbanSettingsView] bulk toggle: some tools failed:', failures)
    const data = await api.getAgentKanban(workspaceId.value, kanbanId)
    kanbanTools.value = data?.tools ?? kanbanTools.value
    if (kanbanKnowledge.value.length === 0 && kanbanSystemPrompts.value.length === 0) {
      void loadKanbanAgent()
    }
  } catch (e) {
    console.error('[KanbanSettingsView] bulk toggle failed:', e)
  }
}

// ─── Handlers (mirror KanbanSettingsDialog 1:1) ────────────────────────────
const handleAddSubmit = () => {
  const trimmedName = newColumnName.value.trim()
  if (!trimmedName) return
  emit('addColumn', trimmedName, newColumnDescription.value.trim())
  newColumnName.value = ''
  newColumnDescription.value = ''
}

const handleEditColumn = (columnId: string) => {
  const col = item.value?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'rename'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
  settingsEditorTargetDescription.value = col.description ?? ''
  showSettingsEditor.value = true
}

const handleDeleteColumn = (columnId: string) => {
  const col = item.value?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'delete'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
  settingsEditorTargetDescription.value = col.description ?? ''
  showSettingsEditor.value = true
}

const handleSettingsEditorClose = () => {
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

const handleSettingsEditorRename = (name: string, description: string) => {
  if (!settingsEditorTargetId.value) return
  emit('editColumn', {
    columnId: settingsEditorTargetId.value,
    name,
    description,
  })
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

const handleSettingsEditorDelete = () => {
  if (!settingsEditorTargetId.value) return
  emit('deleteColumn', settingsEditorTargetId.value)
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

// ─── Navigation ────────────────────────────────────────────────────────────
const goBack = () => {
  // The workspaceId is derived from the store (workspaceId computed
  // above). itemId comes from route.params. If either is missing,
  // fall back to /app so the user doesn't get stuck.
  const wsId = workspaceId.value
  const itId = itemId.value
  if (wsId && itId) {
    // Preserve the board's sub-state (`?sorts=`, `?layout=`, `?detail=`, …) instead of rebuilding
    // the query from scratch. Dropping `sorts` reset every column to the default sort after a visit
    // to board settings, and dropping `layout` lost row mode.
    const sub: Record<string, string> = {}
    for (const [k, v] of Object.entries(route.query)) {
      if (typeof v === 'string') sub[k] = v
      else if (Array.isArray(v)) {
        const first = v.find((x): x is string => typeof x === 'string')
        if (first !== undefined) sub[k] = first
      }
    }
    // The settings page's own params must not leak back onto the board.
    delete sub.tab
    delete sub.section
    void router.replace(buildAppUrl({ workspaceId: wsId, projectId: itId, query: sub }))
  } else {
    router.replace({ path: '/app' })
  }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────── Reset settingsMode
// when the route changes (so navigating from one kanban's settings to another's starts on the
// Columns tab, not the Agent tab that the previous kanban had selected).
// The URL is the source of truth, so we use `router.replace` to strip the ?section= query rather
// than mutating the computed directly. Reset the settings tab/editor when navigating between
// kanbans: prev-id guard on update.
// Writing settingsMode strips ?section= from the URL via its setter; the guard keeps the reset
// one-shot.
const prevSettingsItemId = ref(itemId.value)
onUpdated(() => {
  if (itemId.value !== prevSettingsItemId.value) {
    prevSettingsItemId.value = itemId.value
    settingsMode.value = 'columns'
    showSettingsEditor.value = false
    settingsEditorTargetId.value = null
  }
})

// ─── Helpers ───────────────────────────────────────────────────────────────
// Sorted copy — mirrors KanbanView's sortedColumns computed so a
// re-render during a pending reorder still looks sensible.
function sortedColumns() {
  return (item.value?.kanban_columns ?? []).slice().sort((a, b) => a.position - b.position)
}
</script>

<template>
  <div
    class="flex flex-col h-full"
    style="background-color: var(--semantic-content-bg)"
    data-testid="kanban-settings-page"
  >
    <!-- Empty / not-found states (centered, full-page) -->
    <div
      v-if="emptyHint"
      class="flex-1 flex items-center justify-center p-8"
      data-testid="kanban-settings-page-no-item"
    >
      <p class="text-body" style="color: var(--semantic-text-dim)">
        No kanban selected. Open this page from a kanban board's Settings button.
      </p>
    </div>
    <div
      v-else-if="notFound"
      class="flex-1 flex items-center justify-center p-8"
      data-testid="kanban-settings-page-not-found"
    >
      <p class="text-body" style="color: var(--semantic-text-dim)">
        That kanban doesn't exist or has been deleted.
      </p>
    </div>

    <!-- Real content (header + tabs + body). Using v-if="item"
         (not v-else) so vue-tsc narrows item to non-null in the
         template body. -->
    <template v-if="item">
      <!-- Header bar: back button + page title + kanban name -->
      <div
        class="h-14 px-5 flex items-center gap-3 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <button
          type="button"
          @click="goBack"
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-muted)"
          title="Back to kanban"
          data-testid="kanban-settings-page-back"
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
        <h1
          class="text-lead font-semibold flex items-center gap-2"
          style="color: var(--semantic-text)"
          data-testid="kanban-settings-page-title"
        >
          <UiIcon name="settings" />
          <span>Kanban Settings</span>
          <span style="color: var(--semantic-text-dim)" class="text-body font-normal">·</span>
          <InlineEditableText
            :value="item.name"
            :placeholder="'unnamed kanban'"
            :ariaLabel="'kanban name'"
            :testId="`kanban-settings-page-rename`"
            display-class="text-body font-normal ml-1"
            @save="(newName) => emit('renameItem', newName)"
          />
        </h1>
      </div>

      <!-- Tab strip: Columns | Agent.
           Agent tab now contains both the AgentView (Knowledge + Tools +
           System Prompt) and the Local Memories section (WorkspaceItem-
           MemoriesView when item.path is set). Local Memories is no
           longer a standalone tab. -->
      <div
        class="flex gap-1 px-5 pt-3 pb-0 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
        data-testid="kanban-settings-page-tabs"
      >
        <button
          type="button"
          @click="settingsMode = 'columns'"
          data-testid="kanban-settings-page-tab-columns"
          class="px-3 py-2 text-dense font-medium rounded-t-lg transition-colors"
          :style="
            settingsMode === 'columns'
              ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
              : 'background-color: transparent; color: var(--semantic-text-muted);'
          "
        >
          Columns
        </button>
        <button
          type="button"
          @click="settingsMode = 'agent'"
          data-testid="kanban-settings-page-tab-agent"
          class="px-3 py-2 text-dense font-medium rounded-t-lg transition-colors"
          :style="
            settingsMode === 'agent'
              ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
              : 'background-color: transparent; color: var(--semantic-text-muted);'
          "
        >
          <UiIcon name="robot" class="mr-1" />Agent
        </button>
      </div>

      <!-- Body -->
      <template v-if="settingsMode === 'columns'">
        <!-- Add Column inline form -->
        <div
          class="px-5 py-4 shrink-0"
          style="
            border-bottom: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
          "
          data-testid="kanban-settings-page-add-form"
        >
          <h4 class="text-dense font-semibold mb-2" style="color: var(--semantic-text-dim)">
            Add a new column
          </h4>
          <div class="flex gap-2 mb-2">
            <input
              v-model="newColumnName"
              type="text"
              placeholder="Column name"
              data-testid="kanban-settings-page-add-name"
              class="flex-1 px-3 py-2 rounded-lg text-body outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keyup.enter="handleAddSubmit"
            />
            <button
              type="button"
              @click="handleAddSubmit"
              :disabled="!newColumnName.trim()"
              data-testid="kanban-settings-page-add-submit"
              class="px-3 py-2 rounded-lg text-body font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              <span aria-hidden="true">+</span>
              <span class="ml-1">Add</span>
            </button>
          </div>
          <textarea
            v-model="newColumnDescription"
            :maxlength="500"
            rows="2"
            placeholder="Description (optional) — what does this column mean?"
            data-testid="kanban-settings-page-add-description"
            class="w-full px-3 py-2 rounded-lg text-body outline-none transition-all duration-200 resize-y"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
              font-family: inherit;
            "
          ></textarea>
        </div>

        <!-- Columns list -->
        <div class="flex-1 overflow-y-auto px-5 py-3 min-h-0">
          <div
            v-if="sortedColumns().length === 0"
            class="text-center py-8"
            style="color: var(--semantic-text-dim)"
            data-testid="kanban-settings-page-empty"
          >
            No columns yet. Add one above to get started.
          </div>
          <ul v-else class="space-y-2" data-testid="kanban-settings-page-column-list">
            <li
              v-for="col in sortedColumns()"
              :key="col.id"
              :data-testid="`kanban-settings-page-column-row-${col.id}`"
              class="px-3 py-2.5 rounded-lg flex items-start justify-between gap-3 transition-colors duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
              "
            >
              <div class="flex-1 min-w-0">
                <div
                  class="text-body font-medium truncate"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-settings-page-column-name-${col.id}`"
                >
                  {{ col.name }}
                </div>
                <div
                  v-if="col.description"
                  class="text-dense mt-0.5 truncate"
                  style="color: var(--semantic-text-dim)"
                  :title="col.description"
                  :data-testid="`kanban-settings-page-column-description-${col.id}`"
                >
                  {{ col.description }}
                </div>
                <div
                  v-else
                  class="text-dense mt-0.5 italic"
                  style="color: var(--semantic-text-dim)"
                  :data-testid="`kanban-settings-page-column-description-${col.id}`"
                >
                  No description
                </div>
              </div>
              <div class="flex gap-1 shrink-0">
                <button
                  type="button"
                  @click="handleEditColumn(col.id)"
                  :data-testid="`kanban-settings-page-edit-${col.id}`"
                  class="px-2 py-1 rounded text-dense font-medium transition-opacity duration-200 hover:opacity-80"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text-muted);
                  "
                >
                  Edit
                </button>
                <button
                  type="button"
                  @click="handleDeleteColumn(col.id)"
                  :data-testid="`kanban-settings-page-delete-${col.id}`"
                  class="px-2 py-1 rounded text-dense font-medium transition-opacity duration-200 hover:opacity-80"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--color-red, #ef4444);
                  "
                >
                  Delete
                </button>
              </div>
            </li>
          </ul>
        </div>

        <!-- Copy spec footer -->
        <div
          class="px-5 py-3 shrink-0"
          style="
            border-top: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
          "
        >
          <button
            type="button"
            @click="emit('copySpec')"
            data-testid="kanban-settings-page-copy-spec"
            class="px-3 py-1.5 rounded-lg text-body font-medium transition-opacity duration-200 hover:opacity-80"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text-muted);
            "
          >
            <UiIcon name="clipboard" />
            <span class="ml-1">Copy spec from…</span>
          </button>
          <p class="text-meta mt-2 italic" style="color: var(--semantic-text-dim)">
            Bulk-copy column names + descriptions from another kanban in this workspace. Tasks are
            not copied.
          </p>
        </div>
      </template>

      <!-- Agent tab body — reuses AgentView (agnostic) for kanban.
           Knowledge moved to right column (with System Prompt) per arrow;
           Local Memories moved to left sidebar (with Tools) per arrow via slot. -->
      <div
        v-else-if="settingsMode === 'agent'"
        class="flex-1 min-h-0 overflow-hidden flex flex-col"
        data-testid="kanban-settings-page-agent-panel"
      >
        <AgentView
          :item="item"
          :workspace-id="workspaceId"
          :item-id="item.id"
          :knowledge="kanbanKnowledge"
          :tools="kanbanTools"
          :system-prompts="kanbanSystemPrompts"
          :parent-loading="kanbanAgentLoading"
          @add-knowledge="handleKanbanAddKnowledge"
          @remove-knowledge="handleKanbanRemoveKnowledge"
          @edit-knowledge="handleKanbanEditKnowledge"
          @toggle-tool="handleKanbanToggleTool"
          @toggle-tools-bulk="handleKanbanToggleToolsBulk"
          @add-system-prompt="handleKanbanAddSystemPrompt"
          @edit-system-prompt="handleKanbanEditSystemPrompt"
          @remove-system-prompt="handleKanbanRemoveSystemPrompt"
        >
          <!-- Local Memories moved from bottom bar to main panel per arrow (both arrows point to center) -->
          <template #right-extra>
            <div
              class="shrink-0 rounded-xl p-4"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
              data-testid="kanban-settings-page-agent-memories-section"
            >
              <div v-if="item.path" data-testid="kanban-settings-page-agent-memories">
                <WorkspaceItemMemoriesView :cwd="item.path" :item-name="item.name" />
              </div>
              <div
                v-else
                class="text-dense text-center py-6 px-4 rounded-lg"
                style="
                  color: var(--semantic-text-dim);
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px dashed var(--color-border);
                "
                data-testid="kanban-settings-page-agent-memories-no-path"
              >
                <UiIcon name="folder" class="w-5 h-5 mb-1" />
                <div>No directory is set on this kanban.</div>
                <div class="mt-1">Pick one when creating the kanban to enable local memories.</div>
              </div>
            </div>
          </template>
        </AgentView>
      </div>
    </template>

    <!--
      Per-row rename/delete editor (lifted from KanbanSettingsDialog).
      The state is owned by THIS view so the editor can open
      independently of any AppLayout-level KanbanColumnEditor (e.g.
      the one mounted for the ⋮ menu flow).
    -->
    <KanbanColumnEditor
      :show="showSettingsEditor"
      :mode="settingsEditorMode"
      :initial-name="settingsEditorTargetName"
      :initial-description="settingsEditorTargetDescription"
      @close="handleSettingsEditorClose"
      @rename="handleSettingsEditorRename"
      @delete="handleSettingsEditorDelete"
    />

    <!-- Kanban Agent dialogs — reuse the same dialogs as `item_type='agent'` (AppLayout).
         Mounted here so the AgentView emits inside the settings page can open them. -->
    <AgentKnowledgeDialog
      v-model:show="kanbanKnowledgeDialogOpen"
      :busy="kanbanKnowledgeBusy"
      :error="kanbanKnowledgeError"
      @close="closeKanbanKnowledgeDialog"
      @create="handleKanbanKnowledgeCreate"
    />
    <AgentKnowledgeDetailDialog
      :show="kanbanKnowledgeDetailOpen"
      :row="
        kanbanKnowledgeDetailRow
          ? ({
              ...kanbanKnowledgeDetailRow,
              agent_id: kanbanKnowledgeDetailRow.kanban_id,
            } as unknown as api.AgentKnowledgeRow)
          : null
      "
      :busy="kanbanKnowledgeDetailBusy"
      :error="kanbanKnowledgeDetailError"
      @close="closeKanbanKnowledgeDetailDialog"
      @save="handleKanbanKnowledgeSave"
    />
    <AgentSystemPromptDialog
      :show="kanbanSystemPromptDialogOpen"
      :row="
        kanbanSystemPromptRow
          ? ({
              ...kanbanSystemPromptRow,
              agent_id: kanbanSystemPromptRow.kanban_id,
            } as unknown as api.AgentSystemPromptRow)
          : null
      "
      :busy="kanbanSystemPromptBusy"
      :error="kanbanSystemPromptError"
      @close="closeKanbanSystemPromptDialog"
      @create="handleKanbanSystemPromptCreate"
      @save="handleKanbanSystemPromptSave"
    />
  </div>
</template>

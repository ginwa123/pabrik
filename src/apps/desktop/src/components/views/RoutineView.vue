<!--
  RoutineView — config surface for a Routine workspace item
  (`item_type='routine'`).

  Tabs (mirrors KanbanSettingsView's Columns | Agent strip):
    - Routine: description / instruction / schedule / enabled + Save +
      Run now. Fetches via GET /api/workspaces/:ws/items/:item/routine
      on mount (and when itemId changes), saves via PATCH, fires via
      the store's runRoutineItem.
    - Agent: Tools / System Prompt / Knowledge (+ Local Memories)
      via the shared AgentView, backed by the agent_routines mirror
      (Migration 087). Same data ownership as KanbanSettingsView:
      this view owns the data + API calls, AgentView is presentational.

  Schedule semantics (mirror the backend):
    - '' (empty) = manual-run only, no auto-fire.
    - otherwise a 5-field cron, validated client-side AND server-side.

  Public API:
    props:  item (WorkspaceItem), workspaceId (string), itemId (string)

  Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md
  Routine mode task_1789505553300_1 (option A, mirror agent_kanban_*).
-->
<script setup lang="ts">
import { ref, computed, onMounted, onUpdated } from 'vue'
import {
  getRoutineItem,
  updateRoutineItem,
  type WorkspaceRoutine,
  type WorkspaceItem,
} from '../../api'
import * as api from '../../api'
import { useWorkspacesStore } from '../../stores/workspaces'
import { buildToggle } from '../../stores/agentToolToggle'
import AgentView from './AgentView.vue'
import type { AgnosticKnowledgeRow, AgnosticSystemPromptRow } from './AgentView.vue'
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
import AgentKnowledgeDialog from '../dialogs/AgentKnowledgeDialog.vue'
import AgentKnowledgeDetailDialog from '../dialogs/AgentKnowledgeDetailDialog.vue'
import AgentSystemPromptDialog from '../dialogs/AgentSystemPromptDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const props = defineProps<{
  item: WorkspaceItem
  workspaceId: string
  itemId: string
}>()

const workspacesStore = useWorkspacesStore()

type RoutineTab = 'routine' | 'agent'
const activeTab = ref<RoutineTab>('routine')

const loading = ref(true)
const loadError = ref<string | null>(null)
const saving = ref(false)
const saveError = ref<string | null>(null)
const running = ref(false)
const runError = ref<string | null>(null)

const description = ref('')
const instruction = ref('')
const schedule = ref('')
const enabled = ref(true)
const lastStatus = ref('')
const lastRunAt = ref('')
const nextRunAt = ref('')

async function load() {
  loading.value = true
  loadError.value = null
  try {
    const { routine } = await getRoutineItem(props.workspaceId, props.itemId)
    applyRoutine(routine)
  } catch (err) {
    loadError.value = err instanceof Error ? err.message : String(err)
  } finally {
    loading.value = false
  }
}

function applyRoutine(routine: WorkspaceRoutine) {
  description.value = routine.description ?? ''
  instruction.value = routine.instruction ?? ''
  schedule.value = routine.schedule ?? ''
  enabled.value = routine.enabled
  lastStatus.value = routine.last_status ?? ''
  lastRunAt.value = routine.last_run_at ?? ''
  nextRunAt.value = routine.next_run_at ?? ''
}

// Compact 5-field cron check (empty = manual-only, always valid).
// Mirrors the backend's POSIX parser loosely; the server re-validates
// and returns 400 on anything we let through.
function validateSchedule(expr: string): string | null {
  const trimmed = expr.trim()
  if (trimmed === '') return null
  const fields = trimmed.split(/\s+/)
  if (fields.length !== 5)
    return 'Schedule must have exactly 5 fields (minute hour day-of-month month day-of-week), or be empty for manual-only'
  for (const f of fields) {
    if (!/^[0-9*,\-/]+$/.test(f)) return `Invalid schedule field: "${f}"`
  }
  return null
}

const scheduleError = computed<string | null>(() => validateSchedule(schedule.value))
const canSave = computed(() => !saving.value && scheduleError.value === null)

async function handleSave() {
  if (!canSave.value) return
  saving.value = true
  saveError.value = null
  try {
    const { routine } = await updateRoutineItem(props.workspaceId, props.itemId, {
      description: description.value,
      instruction: instruction.value,
      schedule: schedule.value.trim(),
      enabled: enabled.value,
    })
    applyRoutine(routine)
  } catch (err) {
    saveError.value = err instanceof Error ? err.message : String(err)
  } finally {
    saving.value = false
  }
}

async function handleRunNow() {
  running.value = true
  runError.value = null
  try {
    await workspacesStore.runRoutineItem(props.workspaceId, props.itemId, props.itemId)
    // Refresh status after the fire (last_status flips to success).
    await load()
  } catch (err) {
    runError.value = err instanceof Error ? err.message : String(err)
  } finally {
    running.value = false
  }
}

const statusLine = computed(() => {
  const parts: string[] = []
  if (lastStatus.value) parts.push(`Last: ${lastStatus.value}`)
  if (lastRunAt.value) parts.push(`ran ${lastRunAt.value}`)
  if (nextRunAt.value) parts.push(`next ${nextRunAt.value}`)
  else parts.push('manual-only (no schedule)')
  return parts.join(' · ')
})

// ─── Routine Agent (reuses AgentView, mirrors KanbanSettingsView) ────────── Same ownership split:
// this view owns the data + API calls against the agent_routines mirror (Migration 087); AgentView
// is presentational and emits intents.
const routineKnowledge = ref<api.AgentRoutineKnowledgeRow[]>([])
const routineTools = ref<string[]>([])
const routineSystemPrompts = ref<api.AgentRoutineSystemPromptRow[]>([])

// True while `loadRoutineAgent` is in flight — AgentView's knowledge and system-prompt panels gate
// their skeletons on this. Without it they render "No knowledge files yet." during the fetch, which
// is a false statement about the routine's data.
const routineAgentLoading = ref(false)

async function loadRoutineAgent() {
  const wsId = props.workspaceId
  const id = props.itemId
  if (!id || !wsId) return
  routineAgentLoading.value = true
  try {
    const data = await api.getAgentRoutine(wsId, id)
    if (data) {
      routineKnowledge.value = data.knowledges
      routineTools.value = data.tools
      routineSystemPrompts.value = data.system_prompts
    } else {
      routineKnowledge.value = []
      routineTools.value = []
      routineSystemPrompts.value = []
    }
  } catch (e) {
    console.error('[RoutineView] failed to load routine agent:', e)
  } finally {
    // Cleared on BOTH paths so a failed fetch cannot park the skeleton.
    routineAgentLoading.value = false
  }
}

// ─── AgentView dialog state (mirrors KanbanSettingsView) ───────────────────
const routineKnowledgeDialogOpen = ref(false)
const routineKnowledgeError = ref<string | null>(null)
const routineKnowledgeBusy = ref(false)

const routineKnowledgeDetailOpen = ref(false)
const routineKnowledgeDetailRow = ref<api.AgentRoutineKnowledgeRow | null>(null)
const routineKnowledgeDetailBusy = ref(false)
const routineKnowledgeDetailError = ref<string | null>(null)

const routineSystemPromptDialogOpen = ref(false)
const routineSystemPromptRow = ref<api.AgentRoutineSystemPromptRow | null>(null)
const routineSystemPromptBusy = ref(false)
const routineSystemPromptError = ref<string | null>(null)

function tryParseErrorBody(body: string): string | null {
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') return obj.error
    return null
  } catch {
    return null
  }
}

function handleRoutineAddKnowledge() {
  routineKnowledgeError.value = null
  routineKnowledgeDialogOpen.value = true
}

function closeRoutineKnowledgeDialog() {
  routineKnowledgeDialogOpen.value = false
  routineKnowledgeError.value = null
}

async function handleRoutineKnowledgeCreate(filePath: string, label: string, content: string) {
  const routineId = props.itemId
  if (!routineId) return
  routineKnowledgeBusy.value = true
  routineKnowledgeError.value = null
  try {
    const newRow = await api.addAgentRoutineKnowledge(routineId, filePath, label, content)
    routineKnowledge.value = [...routineKnowledge.value, newRow]
    closeRoutineKnowledgeDialog()
  } catch (e) {
    routineKnowledgeError.value = e instanceof Error ? e.message : 'Failed to add knowledge'
  } finally {
    routineKnowledgeBusy.value = false
  }
}

function handleRoutineEditKnowledge(row: AgnosticKnowledgeRow) {
  routineKnowledgeDetailRow.value = row as api.AgentRoutineKnowledgeRow
  routineKnowledgeDetailError.value = null
  routineKnowledgeDetailOpen.value = true
}

function closeRoutineKnowledgeDetailDialog() {
  routineKnowledgeDetailOpen.value = false
  routineKnowledgeDetailError.value = null
}

async function handleRoutineKnowledgeSave(
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) {
  const routineId = props.itemId
  if (!routineId) return
  routineKnowledgeDetailBusy.value = true
  routineKnowledgeDetailError.value = null
  try {
    const updated = await api.updateAgentRoutineKnowledge(routineId, knowledgeId, updates)
    routineKnowledge.value = routineKnowledge.value.map((k) => (k.id === knowledgeId ? updated : k))
    closeRoutineKnowledgeDetailDialog()
  } catch (e) {
    routineKnowledgeDetailError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update knowledge'
  } finally {
    routineKnowledgeDetailBusy.value = false
  }
}

async function handleRoutineRemoveKnowledge(knowledgeId: string) {
  const routineId = props.itemId
  if (!routineId) return
  const previous = routineKnowledge.value
  routineKnowledge.value = previous.filter((k) => k.id !== knowledgeId)
  try {
    await api.deleteAgentRoutineKnowledge(routineId, knowledgeId)
  } catch (e) {
    routineKnowledge.value = previous
    console.error('[RoutineView] failed to remove knowledge:', e)
  }
}

function handleRoutineAddSystemPrompt() {
  routineSystemPromptRow.value = null
  routineSystemPromptError.value = null
  routineSystemPromptDialogOpen.value = true
}

function handleRoutineEditSystemPrompt(row: AgnosticSystemPromptRow) {
  routineSystemPromptRow.value = row as api.AgentRoutineSystemPromptRow
  routineSystemPromptError.value = null
  routineSystemPromptDialogOpen.value = true
}

function closeRoutineSystemPromptDialog() {
  routineSystemPromptDialogOpen.value = false
  routineSystemPromptError.value = null
}

async function handleRoutineSystemPromptCreate(title: string, content: string) {
  const routineId = props.itemId
  if (!routineId) return
  routineSystemPromptBusy.value = true
  routineSystemPromptError.value = null
  try {
    const newRow = await api.addAgentRoutineSystemPrompt(routineId, title, content)
    routineSystemPrompts.value = [...routineSystemPrompts.value, newRow]
    closeRoutineSystemPromptDialog()
  } catch (e) {
    routineSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to add system prompt'
  } finally {
    routineSystemPromptBusy.value = false
  }
}

async function handleRoutineSystemPromptSave(
  promptId: string,
  updates: { title: string; content: string },
) {
  const routineId = props.itemId
  if (!routineId) return
  routineSystemPromptBusy.value = true
  routineSystemPromptError.value = null
  try {
    const updated = await api.updateAgentRoutineSystemPrompt(routineId, promptId, updates)
    routineSystemPrompts.value = routineSystemPrompts.value.map((p) =>
      p.id === promptId ? updated : p,
    )
    closeRoutineSystemPromptDialog()
  } catch (e) {
    routineSystemPromptError.value =
      e instanceof api.ApiError && e.body
        ? (tryParseErrorBody(e.body) ?? e.message)
        : e instanceof Error
          ? e.message
          : 'Failed to update system prompt'
  } finally {
    routineSystemPromptBusy.value = false
  }
}

async function handleRoutineRemoveSystemPrompt(promptId: string) {
  const routineId = props.itemId
  if (!routineId) return
  const previous = routineSystemPrompts.value
  routineSystemPrompts.value = previous.filter((p) => p.id !== promptId)
  try {
    await api.deleteAgentRoutineSystemPrompt(routineId, promptId)
  } catch (e) {
    routineSystemPrompts.value = previous
    console.error('[RoutineView] failed to remove system prompt:', e)
  }
}

async function handleRoutineToggleTool(toolName: string, enabled: boolean) {
  const routineId = props.itemId
  if (!routineId) return
  const { nextLocal, serverPromise } = buildToggle(
    routineTools.value,
    toolName,
    enabled,
    routineId,
    {
      enableAgentTool: api.enableAgentRoutineTool,
      disableAgentTool: api.disableAgentRoutineTool,
      refetchAgentTools: async (id) => {
        const data = await api.getAgentRoutine(props.workspaceId, id)
        return data?.tools ?? []
      },
    },
  )
  routineTools.value = nextLocal
  const out = await serverPromise
  if ('error' in out) {
    routineTools.value = enabled
      ? routineTools.value.filter((n) => n !== toolName)
      : [...routineTools.value, toolName]
    console.error('[RoutineView] toggle tool failed:', out.error)
    return
  }
  routineTools.value = out.canonical
  if (routineKnowledge.value.length === 0 && routineSystemPrompts.value.length === 0) {
    void loadRoutineAgent()
  }
}

async function handleRoutineToggleToolsBulk(toolNames: string[], enabled: boolean) {
  const routineId = props.itemId
  if (!routineId || toolNames.length === 0) return
  const set = new Set(routineTools.value)
  for (const n of toolNames) {
    if (enabled) set.add(n)
    else set.delete(n)
  }
  routineTools.value = Array.from(set)
  try {
    const ops = toolNames.map(async (n) => {
      try {
        if (enabled) await api.enableAgentRoutineTool(routineId, n)
        else await api.disableAgentRoutineTool(routineId, n)
        return { name: n, ok: true as const }
      } catch (e) {
        return { name: n, ok: false as const, error: e }
      }
    })
    const results = await Promise.all(ops)
    const failures = results.filter((r) => !r.ok)
    if (failures.length > 0)
      console.error('[RoutineView] bulk toggle: some tools failed:', failures)
    const data = await api.getAgentRoutine(props.workspaceId, routineId)
    routineTools.value = data?.tools ?? routineTools.value
    if (routineKnowledge.value.length === 0 && routineSystemPrompts.value.length === 0) {
      void loadRoutineAgent()
    }
  } catch (e) {
    console.error('[RoutineView] bulk toggle failed:', e)
  }
}

onMounted(() => {
  void load()
  void loadRoutineAgent()
})

// Reload on item change (prev-value guard on update — same reset+loads
// the watcher did; mount is covered above).
let prevRoutineItemId = props.itemId
onUpdated(() => {
  if (props.itemId === prevRoutineItemId) return
  prevRoutineItemId = props.itemId
  activeTab.value = 'routine'
  void load()
  void loadRoutineAgent()
})
</script>

<template>
  <div class="flex flex-col gap-4 p-5 max-w-2xl" data-testid="routine-view">
    <div class="flex items-center gap-2">
      <UiIcon name="stopwatch" size-class="w-4.5 h-4.5" />
      <h2 class="text-lead font-semibold" style="color: var(--semantic-text)">
        {{ item.name ?? 'Routine' }}
      </h2>
    </div>

    <div class="flex gap-1" data-testid="routine-tabs">
      <button
        type="button"
        data-testid="routine-tab-routine"
        class="px-3 py-1.5 rounded-lg text-body font-medium"
        :style="
          activeTab === 'routine'
            ? 'background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);'
            : 'background-color: transparent; border: 1px solid transparent; color: var(--semantic-text-dim);'
        "
        @click="activeTab = 'routine'"
      >
        Routine
      </button>
      <button
        type="button"
        data-testid="routine-tab-agent"
        class="px-3 py-1.5 rounded-lg text-body font-medium"
        :style="
          activeTab === 'agent'
            ? 'background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);'
            : 'background-color: transparent; border: 1px solid transparent; color: var(--semantic-text-dim);'
        "
        @click="activeTab = 'agent'"
      >
        <UiIcon name="robot" size-class="w-3.5 h-3.5" /> Agent
      </button>
    </div>

    <template v-if="activeTab === 'routine'">
      <div v-if="loading" class="text-body" style="color: var(--semantic-text-dim)">
        Loading routine…
      </div>

      <div
        v-else-if="loadError"
        class="text-body"
        style="color: var(--color-red)"
        data-testid="routine-error"
      >
        Failed to load routine: {{ loadError }}
      </div>

      <template v-else>
        <p class="text-dense" style="color: var(--semantic-text-dim)" data-testid="routine-status">
          {{ statusLine }}
        </p>

        <div>
          <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text-dim)"
            >Description</label
          >
          <input
            v-model="description"
            type="text"
            placeholder="What is this routine for?"
            data-testid="routine-description"
            class="w-full px-3 py-2 rounded-lg text-body outline-none"
            :style="{
              backgroundColor: 'var(--semantic-sidebar-bg)',
              border: '1px solid var(--color-border)',
              color: 'var(--semantic-text)',
            }"
          />
        </div>

        <div>
          <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text-dim)"
            >Instruction (fired on each run)</label
          >
          <textarea
            v-model="instruction"
            rows="4"
            placeholder="Tell the agent what to do on every fire…"
            data-testid="routine-instruction"
            class="w-full px-3 py-2 rounded-lg text-body outline-none font-mono"
            :style="{
              backgroundColor: 'var(--semantic-sidebar-bg)',
              border: '1px solid var(--color-border)',
              color: 'var(--semantic-text)',
            }"
          />
        </div>

        <div>
          <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text-dim)"
            >Schedule (cron — empty = manual-only)</label
          >
          <input
            v-model="schedule"
            type="text"
            placeholder="0 9 * * *"
            data-testid="routine-schedule"
            :aria-invalid="scheduleError !== null"
            class="w-full px-3 py-2 rounded-lg text-body outline-none font-mono"
            :style="{
              backgroundColor: 'var(--semantic-sidebar-bg)',
              border: `1px solid ${scheduleError ? 'var(--color-red)' : 'var(--color-border)'}`,
              color: 'var(--semantic-text)',
            }"
          />
          <p v-if="scheduleError" class="text-dense mt-1" style="color: var(--color-red)">
            {{ scheduleError }}
          </p>
          <p v-else class="text-dense mt-1" style="color: var(--semantic-text-dim)">
            5 fields: minute hour day-of-month month day-of-week — e.g.
            <span class="font-mono">*/5 * * * *</span>, <span class="font-mono">0 9 * * 1-5</span>
          </p>
        </div>

        <label class="flex items-center gap-2 text-body" style="color: var(--semantic-text)">
          <input v-model="enabled" type="checkbox" data-testid="routine-enabled" />
          Enabled
        </label>

        <p v-if="saveError" class="text-dense" style="color: var(--color-red)">{{ saveError }}</p>
        <p v-if="runError" class="text-dense" style="color: var(--color-red)">{{ runError }}</p>

        <div class="flex gap-2">
          <button
            type="button"
            :disabled="!canSave"
            data-testid="routine-save"
            class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50"
            style="
              background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
              color: var(--color-bg);
            "
            @click="handleSave"
          >
            {{ saving ? 'Saving…' : 'Save' }}
          </button>
          <button
            type="button"
            :disabled="running || !enabled"
            data-testid="routine-run"
            class="px-3 py-1.5 rounded-lg text-body font-medium disabled:opacity-50"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            @click="handleRunNow"
          >
            {{ running ? 'Firing…' : '▶ Run now' }}
          </button>
        </div>
      </template>
    </template>

    <div
      v-else
      class="flex-1 min-h-0 overflow-hidden flex flex-col"
      data-testid="routine-agent-panel"
    >
      <AgentView
        :item="item"
        :workspace-id="workspaceId"
        :item-id="itemId"
        :knowledge="routineKnowledge"
        :tools="routineTools"
        :system-prompts="routineSystemPrompts"
        :parent-loading="routineAgentLoading"
        @add-knowledge="handleRoutineAddKnowledge"
        @remove-knowledge="handleRoutineRemoveKnowledge"
        @edit-knowledge="handleRoutineEditKnowledge"
        @toggle-tool="handleRoutineToggleTool"
        @toggle-tools-bulk="handleRoutineToggleToolsBulk"
        @add-system-prompt="handleRoutineAddSystemPrompt"
        @edit-system-prompt="handleRoutineEditSystemPrompt"
        @remove-system-prompt="handleRoutineRemoveSystemPrompt"
      >
        <template #right-extra>
          <div
            class="shrink-0 rounded-xl p-4"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
            data-testid="routine-agent-memories-section"
          >
            <div v-if="item.path" data-testid="routine-agent-memories">
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
              data-testid="routine-agent-memories-no-path"
            >
              <UiIcon name="folder" size-class="w-4.5 h-4.5" class="mb-1" />
              <div>No directory is set on this routine.</div>
              <div class="mt-1">Pick one when creating the routine to enable local memories.</div>
            </div>
          </div>
        </template>
      </AgentView>
    </div>

    <!-- Routine Agent dialogs — same dialogs as kanban/agent (KanbanSettingsView, AppLayout). -->
    <AgentKnowledgeDialog
      v-model:show="routineKnowledgeDialogOpen"
      :busy="routineKnowledgeBusy"
      :error="routineKnowledgeError"
      @close="closeRoutineKnowledgeDialog"
      @create="handleRoutineKnowledgeCreate"
    />
    <AgentKnowledgeDetailDialog
      :show="routineKnowledgeDetailOpen"
      :row="
        routineKnowledgeDetailRow
          ? ({
              ...routineKnowledgeDetailRow,
              agent_id: routineKnowledgeDetailRow.routine_id,
            } as unknown as api.AgentKnowledgeRow)
          : null
      "
      :busy="routineKnowledgeDetailBusy"
      :error="routineKnowledgeDetailError"
      @close="closeRoutineKnowledgeDetailDialog"
      @save="handleRoutineKnowledgeSave"
    />
    <AgentSystemPromptDialog
      :show="routineSystemPromptDialogOpen"
      :row="
        routineSystemPromptRow
          ? ({
              ...routineSystemPromptRow,
              agent_id: routineSystemPromptRow.routine_id,
            } as unknown as api.AgentSystemPromptRow)
          : null
      "
      :busy="routineSystemPromptBusy"
      :error="routineSystemPromptError"
      @close="closeRoutineSystemPromptDialog"
      @create="handleRoutineSystemPromptCreate"
      @save="handleRoutineSystemPromptSave"
    />
  </div>
</template>

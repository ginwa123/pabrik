<!--
  KanbanKnowledgePanel — per-board persona-content panel for a kanban
  board (Knowledge rows + System Prompt blocks). Mounted as a top-level
  tab body inside KanbanSettingsView at the route
  /app/kanban/:itemId/settings?tab=knowledge (iteration 2 of the
  2026-08-27 plan — the Agent umbrella tab was split into Tools +
  Knowledge as separate top-level tabs).

  Hosts TWO persona-content sections side by side (both injected into
  the agent's system prompt at runtime):
    1. Knowledge    — file-backed + inline-text rows. Reuses
                      AgentKnowledgeDialog + AgentKnowledgeDetailDialog.
    2. System Prompt — named persona blocks. Reuses AgentSystemPromptDialog.

  The tools checkbox grid was MOVED to KanbanToolsPanel.vue (separate
  tab). This panel therefore drops the tools-related imports, the
  `kanban-agent-tools-panel` section, the unconfigured "enable a tool
  to bootstrap" hint (that lives in the Tools tab now).

  History: this file was renamed from KanbanAgentPanel.vue → KanbanKnowledgePanel.vue
  in the iteration-2 split. Before that it was extracted from
  KanbanAgentSettings.vue (the centered modal that used to host all 3
  sections). Same data-testid values kept throughout the rename so
  existing functional + vitest specs keep targeting the same selectors.

  Public API:
    props: item ({ id, name? } | null), workspaceId (string)

-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  getAgentKanban,
  addAgentKanbanKnowledge,
  updateAgentKanbanKnowledge,
  deleteAgentKanbanKnowledge,
  addAgentKanbanSystemPrompt,
  updateAgentKanbanSystemPrompt,
  deleteAgentKanbanSystemPrompt,
  type AgentKanban,
  type AgentKanbanKnowledgeRow,
  type AgentKanbanSystemPromptRow,
} from '../../api'
import type { AgentKnowledgeRow, AgentSystemPromptRow } from '../../api'
import AgentKnowledgeDialog from '../dialogs/AgentKnowledgeDialog.vue'
import AgentKnowledgeDetailDialog from '../dialogs/AgentKnowledgeDetailDialog.vue'
import AgentSystemPromptDialog from '../dialogs/AgentSystemPromptDialog.vue'

const props = withDefaults(
  defineProps<{
    item: { id: string; name?: string } | null
    workspaceId?: string
  }>(),
  { workspaceId: '' },
)

// ─── Board config state ──────────────────────────────────────────────
const loading = ref(false)
const loadError = ref<string | null>(null)
const config = ref<AgentKanban | null>(null)
const knowledges = ref<AgentKanbanKnowledgeRow[]>([])
const systemPrompts = ref<AgentKanbanSystemPromptRow[]>([])

// ─── Sub-dialog state ────────────────────────────────────────────────
const knowledgeAddOpen = ref(false)
const knowledgeEditOpen = ref(false)
const knowledgeEditRow = ref<AgentKanbanKnowledgeRow | null>(null)
const promptDialogOpen = ref(false)
const promptEditRow = ref<AgentKanbanSystemPromptRow | null>(null)

// The reused Agent dialogs expect AgentKnowledgeRow / AgentSystemPromptRow
// (agent_id-keyed). Adapt kanban rows by mapping kanban_id → agent_id —
// the dialogs never send the id field back, so the mapping is lossless.
const knowledgeEditRowAdapted = computed<AgentKnowledgeRow | null>(() => {
  const k = knowledgeEditRow.value
  if (!k) return null
  return { ...k, agent_id: k.kanban_id }
})
const promptEditRowAdapted = computed<AgentSystemPromptRow | null>(() => {
  const p = promptEditRow.value
  if (!p) return null
  return { ...p, agent_id: p.kanban_id }
})

// busy/error shared by all sub-dialogs (only one can be open at a time).
const busy = ref(false)
const dialogError = ref<string | null>(null)

const kanbanId = computed(() => props.item?.id ?? '')

const errText = (err: unknown): string => {
  const msg = err instanceof Error ? err.message : String(err)
  return msg.replace(/^API \d+:\s*/, '')
}

// ─── Load ────────────────────────────────────────────────────────────
const load = async () => {
  if (!kanbanId.value) return
  loading.value = true
  loadError.value = null
  try {
    const data = await getAgentKanban(props.workspaceId ?? '', kanbanId.value)
    if (data) {
      config.value = data.agent_kanban
      knowledges.value = data.knowledges
      systemPrompts.value = data.system_prompts
    } else {
      // 404 "not configured" — expected state. The user bootstraps
      // the config by enabling a tool on the Tools tab; Knowledge
      // + System Prompt rows can only exist once that row exists.
      config.value = null
      knowledges.value = []
      systemPrompts.value = []
    }
  } catch (err) {
    loadError.value = errText(err)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  void load()
})

// ─── Knowledge handlers ──────────────────────────────────────────────
const handleKnowledgeCreate = async (filePath: string, label: string, content: string) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const row = await addAgentKanbanKnowledge(config.value.id, filePath, label, content)
    knowledges.value.unshift(row)
    knowledgeAddOpen.value = false
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handleKnowledgeSave = async (
  knowledgeId: string,
  updates: { label: string; file_path?: string; content?: string },
) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const updated = await updateAgentKanbanKnowledge(config.value.id, knowledgeId, updates)
    const idx = knowledges.value.findIndex((k) => k.id === knowledgeId)
    if (idx >= 0) knowledges.value.splice(idx, 1, updated)
    knowledgeEditOpen.value = false
    knowledgeEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handleKnowledgeRemove = async (knowledgeId: string) => {
  if (!config.value) return
  const idx = knowledges.value.findIndex((k) => k.id === knowledgeId)
  const backup = idx >= 0 ? knowledges.value[idx] : null
  if (idx < 0 || !backup) return
  knowledges.value.splice(idx, 1) // optimistic
  try {
    await deleteAgentKanbanKnowledge(config.value.id, knowledgeId)
  } catch (err) {
    knowledges.value.splice(idx, 0, backup) // revert
    loadError.value = errText(err)
  }
}

// ─── System prompt handlers ──────────────────────────────────────────
const handlePromptCreate = async (title: string, content: string) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const row = await addAgentKanbanSystemPrompt(config.value.id, title, content)
    systemPrompts.value.unshift(row)
    promptDialogOpen.value = false
    promptEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handlePromptSave = async (promptId: string, updates: { title: string; content: string }) => {
  if (!config.value) return
  busy.value = true
  dialogError.value = null
  try {
    const updated = await updateAgentKanbanSystemPrompt(config.value.id, promptId, updates)
    const idx = systemPrompts.value.findIndex((p) => p.id === promptId)
    if (idx >= 0) systemPrompts.value.splice(idx, 1, updated)
    promptDialogOpen.value = false
    promptEditRow.value = null
  } catch (err) {
    dialogError.value = errText(err)
  } finally {
    busy.value = false
  }
}

const handlePromptRemove = async (promptId: string) => {
  if (!config.value) return
  const idx = systemPrompts.value.findIndex((p) => p.id === promptId)
  const backup = idx >= 0 ? systemPrompts.value[idx] : null
  if (idx < 0 || !backup) return
  systemPrompts.value.splice(idx, 1) // optimistic
  try {
    await deleteAgentKanbanSystemPrompt(config.value.id, promptId)
  } catch (err) {
    systemPrompts.value.splice(idx, 0, backup) // revert
    loadError.value = errText(err)
  }
}
</script>

<template>
  <div data-testid="kanban-knowledge-panel">
    <div
      v-if="loading"
      class="px-5 py-8 text-body text-center"
      style="color: var(--semantic-text-dim)"
      data-testid="kanban-knowledge-loading"
    >
      Loading…
    </div>
    <div
      v-else-if="loadError && !config"
      class="px-5 py-6 text-body text-center"
      style="color: rgb(239, 68, 68)"
      data-testid="kanban-knowledge-error"
    >
      {{ loadError }}
    </div>

    <!-- Body: 2 persona-content sections. Bootstrap hint appears
         when the agent_kanban row hasn't been created yet (user
         needs to enable a tool on the Tools tab first). -->
    <div
      v-else-if="config"
      class="px-5 py-5 overflow-y-auto flex flex-col gap-5"
      style="max-height: calc(100vh - 14rem)"
    >
      <!-- ─── Knowledge section ─── -->
      <section data-testid="kanban-agent-knowledge-panel">
        <div class="flex items-center justify-between mb-2">
          <h4 class="text-body font-semibold" style="color: var(--semantic-text)">
            Knowledge
            <span class="ml-1 text-dense font-normal" style="color: var(--semantic-text-dim)">
              ({{ knowledges.length }})
            </span>
          </h4>
          <button
            type="button"
            class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text-muted);
            "
            data-testid="kanban-agent-knowledge-add"
            @click="knowledgeAddOpen = true"
          >
            <span aria-hidden="true">✚</span> Add
          </button>
        </div>
        <ul v-if="knowledges.length" class="flex flex-col gap-1">
          <li
            v-for="k in knowledges"
            :key="k.id"
            class="flex items-center gap-2 px-3 py-2 rounded-lg text-dense"
            style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border)"
            :data-testid="`kanban-agent-knowledge-row-${k.id}`"
          >
            <span class="truncate flex-1" style="color: var(--semantic-text)">
              {{ k.label || (k.content ? 'Inline knowledge' : k.file_path.split('/').pop()) }}
            </span>
            <button
              type="button"
              class="shrink-0 hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              :aria-label="`Edit knowledge ${k.label || k.id}`"
              :data-testid="`kanban-agent-knowledge-edit-${k.id}`"
              @click="
                () => {
                  knowledgeEditRow = k
                  knowledgeEditOpen = true
                }
              "
            >
              ✎
            </button>
            <button
              type="button"
              class="shrink-0 hover:opacity-70"
              style="color: rgb(239, 68, 68)"
              :aria-label="`Remove knowledge ${k.label || k.id}`"
              :data-testid="`kanban-agent-knowledge-remove-${k.id}`"
              @click="handleKnowledgeRemove(k.id)"
            >
              ✕
            </button>
          </li>
        </ul>
        <p
          v-else
          class="text-dense"
          style="color: var(--semantic-text-dim)"
          data-testid="kanban-agent-knowledge-empty"
        >
          No knowledge entries yet.
        </p>
      </section>

      <!-- ─── System Prompt section ─── -->
      <section data-testid="kanban-agent-system-prompt-panel">
        <div class="flex items-center justify-between mb-2">
          <h4 class="text-body font-semibold" style="color: var(--semantic-text)">
            System Prompt
            <span class="ml-1 text-dense font-normal" style="color: var(--semantic-text-dim)">
              ({{ systemPrompts.length }})
            </span>
          </h4>
          <button
            type="button"
            class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
            style="
              background-color: var(--semantic-sidebar-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text-muted);
            "
            data-testid="kanban-agent-system-prompt-add"
            @click="
              () => {
                promptEditRow = null
                promptDialogOpen = true
              }
            "
          >
            <span aria-hidden="true">✚</span> Add
          </button>
        </div>
        <ul v-if="systemPrompts.length" class="flex flex-col gap-1">
          <li
            v-for="p in systemPrompts"
            :key="p.id"
            class="flex items-center gap-2 px-3 py-2 rounded-lg text-dense"
            style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border)"
            :data-testid="`kanban-agent-system-prompt-row-${p.id}`"
          >
            <span class="truncate flex-1" style="color: var(--semantic-text)">
              {{ p.title || 'Untitled prompt' }}
            </span>
            <button
              type="button"
              class="shrink-0 hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              :aria-label="`Edit system prompt ${p.title || p.id}`"
              :data-testid="`kanban-agent-system-prompt-edit-${p.id}`"
              @click="
                () => {
                  promptEditRow = p
                  promptDialogOpen = true
                }
              "
            >
              ✎
            </button>
            <button
              type="button"
              class="shrink-0 hover:opacity-70"
              style="color: rgb(239, 68, 68)"
              :aria-label="`Remove system prompt ${p.title || p.id}`"
              :data-testid="`kanban-agent-system-prompt-remove-${p.id}`"
              @click="handlePromptRemove(p.id)"
            >
              ✕
            </button>
          </li>
        </ul>
        <p
          v-else
          class="text-dense"
          style="color: var(--semantic-text-dim)"
          data-testid="kanban-agent-system-prompt-empty"
        >
          No system prompts yet.
        </p>
      </section>

      <!-- Non-fatal mutation error banner -->
      <p
        v-if="loadError && config"
        class="text-dense px-3 py-2 rounded-lg"
        style="color: rgb(239, 68, 68); background-color: rgba(239, 68, 68, 0.08)"
        data-testid="kanban-knowledge-mutation-error"
      >
        {{ loadError }}
      </p>
    </div>

    <!-- Unconfigured: this board has no agent_kanbans row yet (the
         user must enable a tool on the Tools tab to bootstrap). -->
    <div
      v-else
      class="px-5 py-8 flex flex-col items-center gap-3"
      data-testid="kanban-knowledge-unconfigured"
    >
      <p class="text-body text-center" style="color: var(--semantic-text-dim)">
        No knowledge or system prompt entries yet. Enable a tool on the
        <strong>Tools</strong> tab first to create this board's agent
        config, then come back here.
      </p>
    </div>

    <!-- Sub-dialogs (reuse the Agent dialogs verbatim) -->
    <AgentKnowledgeDialog
      :show="knowledgeAddOpen"
      :busy="busy"
      :error="dialogError"
      @close="knowledgeAddOpen = false"
      @create="handleKnowledgeCreate"
    />
    <AgentKnowledgeDetailDialog
      :show="knowledgeEditOpen"
      :row="knowledgeEditRowAdapted"
      :busy="busy"
      :error="dialogError"
      @close="
        () => {
          knowledgeEditOpen = false
          knowledgeEditRow = null
        }
      "
      @save="handleKnowledgeSave"
    />
    <AgentSystemPromptDialog
      :show="promptDialogOpen"
      :row="promptEditRowAdapted"
      :busy="busy"
      :error="dialogError"
      @close="
        () => {
          promptDialogOpen = false
          promptEditRow = null
        }
      "
      @create="handlePromptCreate"
      @save="handlePromptSave"
    />
  </div>
</template>

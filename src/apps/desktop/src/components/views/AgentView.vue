<!--
  AgentView — main view for `item_type='agent'` workspace items.

  Three sections (per spec D11):
    1. Knowledge panel — list of markdown paths with add/remove
    2. Tools panel — searchable, bulk-operable checkbox list rendered
       from agentTools registry
    3. Chat list (right column) — existing workspace_item_tasks filtered

  Plan: 2026-08-15-agent-mode (Task 17)
  UI/UX polish: 2026-08-20 (task_1787254463604_3) — added a search
  filter, an enabled-count chip, Select all / Clear all bulk ops,
  full-description tooltips, hover state on remove buttons, and a
  better empty state.
-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import * as api from '../../api'
import { useAgentToolsStore } from '../../stores/agentTools'
import type { WorkspaceItem } from '../../stores/workspaces'
import UiIcon from '../ui/UiIcon.vue'

/**  * Agnostic row types — AgentView is reused for `item_type='agent'`, kanban boards and routines.
 * `routine_id`; all other fields are identical. `id`, `title`, `content` (system prompts), so a
 * union is safe. */
export type AgnosticKnowledgeRow = api.AgentKnowledgeRow | api.AgentKanbanKnowledgeRow | api.AgentRoutineKnowledgeRow
export type AgnosticSystemPromptRow = api.AgentSystemPromptRow | api.AgentKanbanSystemPromptRow | api.AgentRoutineSystemPromptRow

interface Props {
  item: WorkspaceItem
  workspaceId: string
  itemId: string
  knowledge: AgnosticKnowledgeRow[]
  tools: string[]
  systemPrompts?: AgnosticSystemPromptRow[]
  /** True while the PARENT's agent-bundle fetch is in flight. */
  parentLoading?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  systemPrompts: () => [],
  parentLoading: false,
})

const emit = defineEmits<{
  addKnowledge: []
  removeKnowledge: [knowledgeId: string]
  editKnowledge: [row: AgnosticKnowledgeRow]
  toggleTool: [toolName: string, enabled: boolean]
  toggleToolsBulk: [toolNames: string[], enabled: boolean]
  selectTask: [taskId: string]
  addSystemPrompt: []
  editSystemPrompt: [row: AgnosticSystemPromptRow]
  removeSystemPrompt: [promptId: string]
}>()

const agentToolsStore = useAgentToolsStore()
const loading = ref(true)

// ─── Tools panel UI state ─────────────────────────────────────────────── `searchQuery` filters
// the registry by name OR description (case- insensitive).
const searchQuery = ref('')
const toolsFilter = ref<'all' | 'enabled' | 'disabled'>('all')
const expandedTools = ref(new Set<string>())

const trimmedQuery = computed(() => searchQuery.value.trim().toLowerCase())

const filteredTools = computed(() => {
  const q = trimmedQuery.value
  return agentToolsStore.registry.filter((t) => {
    if (toolsFilter.value === 'enabled' && !enabledToolSet.value.has(t.name)) return false
    if (toolsFilter.value === 'disabled' && enabledToolSet.value.has(t.name)) return false
    if (q.length === 0) return true
    return (
      t.name.toLowerCase().includes(q) ||
      t.description.toLowerCase().includes(q)
    )
  })
})

function toggleToolExpanded(name: string) {
  const next = new Set(expandedTools.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  expandedTools.value = next
}

// ─── System Prompt panel UI state (plan 2026-08-21-agent-system-prompt) ──
// `expandedPrompts` tracks which prompt rows show their full content —
// same expand-chevron pattern as the Knowledge panel.
const expandedPrompts = ref(new Set<string>())

function togglePromptExpanded(id: string) {
  const next = new Set(expandedPrompts.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedPrompts.value = next
}

function promptPreview(content: string): string {
  const oneLine = content.replace(/\s+/g, ' ').trim()
  return oneLine.length > 60 ? oneLine.slice(0, 60) + '…' : oneLine
}

// ─── Knowledge panel UI state ─────────────────────────────────────────── `expandedKnowledge`
// tracks which knowledge rows are expanded. Expanded inline rows reveal their full content in a
// scrollable block; expanded file-backed rows show the absolute path + a hint line.
const expandedKnowledge = ref(new Set<string>())

function toggleKnowledgeExpanded(id: string) {
  const next = new Set(expandedKnowledge.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expandedKnowledge.value = next
}

async function copyKnowledgeContent(text: string) {
  try {
    await navigator.clipboard.writeText(text)
  } catch {
    // Clipboard can fail (permissions / non-secure context) — non-fatal.
  }
}

const enabledToolSet = computed(() => new Set(props.tools))

// Live counts for the All / Enabled / Disabled filter chips.
const enabledFilterCount = computed(() => props.tools.length)
const disabledFilterCount = computed(() =>
  agentToolsStore.registry.length - props.tools.length,
)

const enabledCountInFiltered = computed(() => {
  let n = 0
  for (const t of filteredTools.value) if (enabledToolSet.value.has(t.name)) n += 1
  return n
})

const allFilteredEnabled = computed(() => {
  const f = filteredTools.value
  if (f.length === 0) return false
  return f.every((t) => enabledToolSet.value.has(t.name))
})

onMounted(async () => {
  loading.value = true
  try {
    await agentToolsStore.fetchRegistry()
  } finally {
    loading.value = false
  }
})

function isToolEnabled(name: string): boolean {
  return enabledToolSet.value.has(name)
}

function basename(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

async function handleToggleTool(name: string, event: Event) {
  const checked = (event.target as HTMLInputElement).checked
  emit('toggleTool', name, checked)
}

function handleSelectAllVisible() {
  // Emit one bulk event with the names currently NOT enabled.
  // Bulk handlers in the parent can dedupe + run them in parallel.
  const toEnable = filteredTools.value
    .filter((t) => !enabledToolSet.value.has(t.name))
    .map((t) => t.name)
  if (toEnable.length > 0) emit('toggleToolsBulk', toEnable, true)
}

function handleClearAllVisible() {
  const toDisable = filteredTools.value
    .filter((t) => enabledToolSet.value.has(t.name))
    .map((t) => t.name)
  if (toDisable.length > 0) emit('toggleToolsBulk', toDisable, false)
}

</script>

<template>
  <div class="flex h-full" data-testid="agent-view">
    <!-- Left column: Tools panel (Knowledge moved to right per arrow) -->
    <div class="w-96 border-r overflow-y-auto p-5" style="border-color: var(--color-border);">
      <!-- Tools panel (card for consistency with right panels) -->
      <section data-testid="agent-tools-panel" class="rounded-xl p-4" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2">
            <h2 class="text-body font-semibold" style="color: var(--semantic-text);">
              Tools
            </h2>
            <span
              data-testid="agent-tools-count"
              class="text-micro font-semibold px-1.5 py-0.5 rounded-full"
              :style="{
                backgroundColor: tools.length > 0 ? 'var(--color-violet)' : 'var(--semantic-card-bg)',
                color: tools.length > 0 ? 'var(--color-bg)' : 'var(--semantic-text-dim)',
                border: tools.length > 0 ? 'none' : '1px solid var(--color-border)',
              }"
              :title="`${tools.length} of ${agentToolsStore.registry.length} tools enabled`"
            >
              {{ tools.length }} / {{ agentToolsStore.registry.length }}
            </span>
          </div>
        </div>
        <p class="text-dense mb-3" style="color: var(--semantic-text-dim);">
          Toggle to give this Agent capabilities. Empty = pure chat (no tools).
        </p>

        <div v-if="agentToolsStore.error" data-testid="agent-tools-error" class="text-dense p-2 rounded mb-2" style="background: var(--color-red); color: var(--color-bg);">
          Tool registry unavailable.
        </div>

        <!-- Search filter + bulk ops (visible once the registry is loaded) -->
        <div v-if="!loading && !agentToolsStore.error" class="mb-2 space-y-2">
          <div class="relative flex items-center" data-testid="agent-tools-search-container">
            <input
              v-model="searchQuery"
              type="text"
              placeholder="Search tools…"
              aria-label="Search tools by name or description"
              class="w-full px-2 py-1.5 pr-7 rounded text-dense outline-none focus:ring-1"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              data-testid="agent-tools-search"
            />
            <button
              v-if="searchQuery"
              type="button"
              @click="searchQuery = ''"
              class="absolute right-1 w-5 h-5 flex items-center justify-center rounded hover:opacity-80"
              style="color: var(--semantic-text-dim);"
              data-testid="agent-tools-search-clear"
              aria-label="Clear search"
              title="Clear search"
            >
              ✕
            </button>
          </div>
          <!-- Filter chips: All / Enabled / Disabled (composes with search) -->
          <div class="flex items-center gap-1" role="group" aria-label="Filter tools by enabled state" data-testid="agent-tools-filter-chips">
            <button
              type="button"
              @click="toolsFilter = 'all'"
              :data-testid="`agent-tools-filter-all`"
              :aria-pressed="toolsFilter === 'all'"
              class="text-meta px-2 py-0.5 rounded-full font-medium transition-colors"
              :style="toolsFilter === 'all'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'"
            >
              All ({{ agentToolsStore.registry.length }})
            </button>
            <button
              type="button"
              @click="toolsFilter = 'enabled'"
              data-testid="agent-tools-filter-enabled"
              :aria-pressed="toolsFilter === 'enabled'"
              class="text-meta px-2 py-0.5 rounded-full font-medium transition-colors"
              :style="toolsFilter === 'enabled'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'"
            >
              Enabled ({{ enabledFilterCount }})
            </button>
            <button
              type="button"
              @click="toolsFilter = 'disabled'"
              data-testid="agent-tools-filter-disabled"
              :aria-pressed="toolsFilter === 'disabled'"
              class="text-meta px-2 py-0.5 rounded-full font-medium transition-colors"
              :style="toolsFilter === 'disabled'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'"
            >
              Disabled ({{ disabledFilterCount }})
            </button>
          </div>
          <div class="flex items-center justify-between text-meta" style="color: var(--semantic-text-dim);">
            <span data-testid="agent-tools-filter-status">
              <template v-if="trimmedQuery.length === 0 && toolsFilter === 'all'">
                Showing all {{ filteredTools.length }} tools
              </template>
              <template v-else>
                Showing {{ enabledCountInFiltered }} / {{ filteredTools.length }} matching
              </template>
            </span>
            <div class="flex items-center gap-2">
              <button
                type="button"
                :disabled="allFilteredEnabled || filteredTools.length === 0"
                @click="handleSelectAllVisible"
                data-testid="agent-tools-select-all"
                class="font-medium disabled:opacity-40 disabled:cursor-not-allowed hover:underline"
                style="color: var(--color-violet);"
                :title="allFilteredEnabled ? 'All visible tools are already enabled' : 'Enable all visible tools'"
              >
                Select all
              </button>
              <span aria-hidden="true">·</span>
              <button
                type="button"
                :disabled="enabledCountInFiltered === 0"
                @click="handleClearAllVisible"
                data-testid="agent-tools-clear-all"
                class="font-medium disabled:opacity-40 disabled:cursor-not-allowed hover:underline"
                style="color: var(--semantic-text-muted);"
                :title="enabledCountInFiltered === 0 ? 'No visible tools are enabled' : 'Disable all visible tools'"
              >
                Clear
              </button>
            </div>
          </div>
        </div>

        <div v-if="loading" class="text-dense" style="color: var(--semantic-text-dim);" data-testid="agent-tools-loading">
          Loading tool registry…
        </div>
        <div
          v-else-if="filteredTools.length === 0 && trimmedQuery.length > 0"
          class="text-dense p-3 rounded"
          style="color: var(--semantic-text-dim); background: var(--semantic-sidebar-bg);"
          data-testid="agent-tools-empty-search"
        >
          No tools match <strong>“{{ searchQuery }}”</strong>.
          <button
            type="button"
            @click="searchQuery = ''"
            class="ml-1 underline"
            style="color: var(--color-violet);"
          >Clear search</button>
        </div>
        <div
          v-else-if="filteredTools.length === 0 && toolsFilter !== 'all'"
          class="text-dense p-3 rounded space-y-1.5"
          style="color: var(--semantic-text-dim); background: var(--semantic-sidebar-bg);"
          data-testid="agent-tools-empty-filter"
        >
          <div>
            No {{ toolsFilter === 'enabled' ? 'enabled' : 'disabled' }} tools{{ trimmedQuery.length > 0 ? ' match this search' : '' }}.
          </div>
          <button
            type="button"
            @click="toolsFilter = 'all'"
            data-testid="agent-tools-empty-filter-reset"
            class="underline font-medium"
            style="color: var(--color-violet);"
          >Show all tools</button>
        </div>
        <ul v-else class="space-y-1 max-h-[60vh] overflow-y-auto pr-1" data-testid="agent-tools-list">
          <li
            v-for="tool in filteredTools"
            :key="tool.name"
            data-testid="agent-tool-item"
            class="flex items-start gap-2 p-2 rounded border transition-colors hover:brightness-110"
            :style="{
              backgroundColor: isToolEnabled(tool.name) ? 'var(--semantic-active-bg)' : 'var(--semantic-sidebar-bg)',
              borderColor: isToolEnabled(tool.name) ? 'var(--color-violet)' : 'var(--color-border)',
              opacity: 1,
            }"
          >
            <input
              type="checkbox"
              :id="`tool-${tool.name}`"
              :checked="isToolEnabled(tool.name)"
              @change="(e) => handleToggleTool(tool.name, e)"
              :data-testid="`agent-tool-checkbox-${tool.name}`"
              class="mt-0.5 shrink-0 cursor-pointer"
            />
            <div class="flex-1 min-w-0">
              <label :for="`tool-${tool.name}`" class="text-dense cursor-pointer flex items-center gap-2">
                <span class="font-mono font-semibold" style="color: var(--semantic-text);">{{ tool.name }}</span>
                <span
                  v-if="isToolEnabled(tool.name)"
                  data-testid="agent-tool-enabled-chip"
                  class="text-micro uppercase tracking-wider font-bold px-1 py-px rounded"
                  style="background: var(--color-violet); color: var(--color-bg);"
                >ON</span>
              </label>
              <!-- Description: 2-line clamp by default, full text when expanded.
                   Clicking the row (not the checkbox) toggles expansion. -->
              <div
                class="text-meta mt-0.5 leading-snug cursor-pointer"
                :class="{ 'agent-desc-clamped': !expandedTools.has(tool.name) }"
                style="color: var(--semantic-text-dim);"
                :title="tool.description"
                :data-testid="`agent-tool-desc-${tool.name}`"
                @click="toggleToolExpanded(tool.name)"
              >
                {{ tool.description }}
              </div>
            </div>
            <button
              type="button"
              @click.stop="toggleToolExpanded(tool.name)"
              :data-testid="`agent-tool-expand-${tool.name}`"
              class="shrink-0 w-4 h-4 mt-0.5 flex items-center justify-center rounded hover:opacity-80 transition-transform"
              :style="{ color: 'var(--semantic-text-dim)', transform: expandedTools.has(tool.name) ? 'rotate(90deg)' : 'none' }"
              :aria-expanded="expandedTools.has(tool.name)"
              :aria-label="expandedTools.has(tool.name) ? 'Collapse description' : 'Expand description'"
              title="Show / hide full description"
            >
              ▸
            </button>
          </li>
        </ul>
      </section>

    </div>

    <!-- Right column: System Prompt → Local Memories → Knowledge (ordered per user request) -->
    <div class="flex-1 flex flex-col p-5 gap-6 overflow-y-auto">
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lead font-semibold" style="color: var(--semantic-text);">
          {{ props.item.name || 'Agent' }}
        </h2>
      </div>

      <!-- System Prompt section (plan 2026-08-21-agent-system-prompt):
           list of named prompt blocks injected into every chat with this
           agent, before its knowledge. Mirrors the Knowledge panel's row
           pattern (expand chevron + ✎/✕). -->
      <section data-testid="agent-system-prompt-panel" class="rounded-xl p-4" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <UiIcon name="note" size-class="w-3.5 h-3.5" />
            <h3 class="text-body font-semibold" style="color: var(--semantic-text);">System Prompt</h3>
            <span
              class="text-micro font-semibold px-1.5 py-0.5 rounded-full"
              :style="{
                backgroundColor: systemPrompts.length > 0 ? 'var(--color-violet)' : 'var(--semantic-card-bg)',
                color: systemPrompts.length > 0 ? 'var(--color-bg)' : 'var(--semantic-text-dim)',
                border: systemPrompts.length > 0 ? 'none' : '1px solid var(--color-border)',
              }"
            >{{ systemPrompts.length }}</span>
          </div>
          <button
            type="button"
            @click="emit('addSystemPrompt')"
            data-testid="agent-add-system-prompt"
            class="text-dense px-2 py-1 rounded font-medium hover:opacity-80"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
          >
            + Add
          </button>
        </div>

        <!-- Parent-fetch skeleton — same rationale as the knowledge panel. -->
        <div
          v-if="props.parentLoading"
          class="space-y-1.5"
          data-testid="agent-system-prompt-skeleton"
          role="status"
          aria-label="Loading system prompts"
        >
          <div
            v-for="n in 2"
            :key="n"
            class="h-9 rounded border animate-pulse"
            style="background-color: var(--semantic-active-bg); border-color: var(--color-border)"
          />
        </div>
        <div v-else-if="systemPrompts.length === 0" class="text-dense text-center py-6 px-4 rounded-lg" style="color: var(--semantic-text-dim); background-color: var(--semantic-sidebar-bg); border: 1px dashed var(--color-border);">
          <UiIcon name="note" size-class="w-4.5 h-4.5" class="mb-1" />
          <div>No system prompts yet.</div>
          <div class="mt-1">Add one to give this Agent a persona or standing instructions.</div>
        </div>

        <ul v-else class="space-y-1.5">
          <li
            v-for="p in systemPrompts"
            :key="p.id"
            data-testid="agent-system-prompt-item"
            class="group p-2 rounded border"
            style="background: var(--semantic-sidebar-bg); border-color: var(--color-border);"
          >
            <div class="flex items-center gap-2">
              <button
                type="button"
                @click="togglePromptExpanded(p.id)"
                :data-testid="'agent-system-prompt-expand-' + p.id"
                class="text-micro shrink-0"
                style="color: var(--semantic-text-muted);"
                :aria-label="expandedPrompts.has(p.id) ? 'Collapse prompt' : 'Expand prompt'"
              >
                {{ expandedPrompts.has(p.id) ? '▾' : '▸' }}
              </button>
              <div class="min-w-0 flex-1 cursor-pointer" @click="togglePromptExpanded(p.id)">
                <div class="text-body font-medium truncate" style="color: var(--semantic-text);">
                  {{ p.title || 'Untitled prompt' }}
                </div>
                <div class="text-dense truncate" style="color: var(--semantic-text-dim);">
                  {{ promptPreview(p.content) }}
                </div>
              </div>
              <button
                type="button"
                @click.stop="emit('editSystemPrompt', p)"
                data-testid="agent-edit-system-prompt"
                class="opacity-0 group-hover:opacity-100 transition-opacity text-dense px-1 rounded hover:bg-white/10"
                style="color: var(--semantic-text-muted);"
                aria-label="Edit system prompt"
                title="Edit"
              >✎</button>
              <button
                type="button"
                @click.stop="emit('removeSystemPrompt', p.id)"
                data-testid="agent-remove-system-prompt"
                class="opacity-0 group-hover:opacity-100 transition-opacity text-dense px-1 rounded hover:bg-white/10"
                style="color: var(--color-red);"
                aria-label="Remove system prompt"
                title="Remove"
              >✕</button>
            </div>
            <pre
              v-if="expandedPrompts.has(p.id)"
              :data-testid="'agent-system-prompt-detail-' + p.id"
              class="mt-2 text-dense whitespace-pre-wrap break-words max-h-48 overflow-y-auto rounded p-2"
              style="background: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-dim); font-family: inherit;"
            >{{ p.content }}</pre>
          </li>
        </ul>
      </section>

      <!-- Slot for extra right content (e.g. Local Memories in Kanban Settings per arrow - both arrows point to main panel) -->
      <slot name="right-extra" />

      <!-- Knowledge panel -->
      <section data-testid="agent-knowledge-panel" class="rounded-xl p-4" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <UiIcon name="books" size-class="w-3.5 h-3.5" />
            <h2 class="text-body font-semibold" style="color: var(--semantic-text);">
              Knowledge
            </h2>
            <span
              data-testid="agent-knowledge-count"
              class="text-micro font-semibold px-1.5 py-0.5 rounded-full"
              :style="{
                backgroundColor: knowledge.length > 0 ? 'var(--color-violet)' : 'var(--semantic-card-bg)',
                color: knowledge.length > 0 ? 'var(--color-bg)' : 'var(--semantic-text-dim)',
                border: knowledge.length > 0 ? 'none' : '1px solid var(--color-border)',
              }"
            >
              {{ knowledge.length }}
            </span>
          </div>
          <button
            type="button"
            @click="emit('addKnowledge')"
            data-testid="agent-add-knowledge"
            class="text-dense px-2.5 py-1 rounded-lg font-medium hover:opacity-90 transition-opacity"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
          >
            + Add
          </button>
        </div>
        <!-- Parent-fetch skeleton — shown while the parent's agent-bundle
             fetch is in flight. Without it the empty state below fires the
             instant `knowledge.length === 0`, which on a cold load is a
             false "No knowledge files yet." -->
        <div
          v-if="props.parentLoading"
          class="space-y-1.5 mt-2"
          data-testid="agent-knowledge-skeleton"
          role="status"
          aria-label="Loading knowledge"
        >
          <div
            v-for="n in 3"
            :key="n"
            class="h-9 rounded border animate-pulse"
            style="background-color: var(--semantic-active-bg); border-color: var(--color-border)"
          />
        </div>
        <div v-else-if="knowledge.length === 0" class="text-dense text-center py-6 px-4 rounded-lg" style="color: var(--semantic-text-dim); background-color: var(--semantic-sidebar-bg); border: 1px dashed var(--color-border);">
          <UiIcon name="books" size-class="w-4.5 h-4.5" class="mb-1" />
          <div>No knowledge files yet.</div>
          <div class="mt-1">Click <strong>+ Add</strong> to attach a markdown file the agent will read on every chat start.</div>
        </div>
        <ul v-else class="space-y-1.5 mt-2">
          <li
            v-for="k in knowledge"
            :key="k.id"
            data-testid="agent-knowledge-item"
            class="group p-2 rounded border"
            style="background: var(--semantic-sidebar-bg); border-color: var(--color-border);"
          >
            <div class="flex items-start gap-2">
              <button
                type="button"
                @click="toggleKnowledgeExpanded(k.id)"
                :data-testid="`agent-knowledge-expand-${k.id}`"
                class="shrink-0 w-4 h-4 mt-0.5 flex items-center justify-center rounded hover:opacity-80 transition-transform"
                :style="{ color: 'var(--semantic-text-dim)', transform: expandedKnowledge.has(k.id) ? 'rotate(90deg)' : 'none' }"
                :aria-expanded="expandedKnowledge.has(k.id)"
                :aria-label="expandedKnowledge.has(k.id) ? 'Collapse details' : 'Expand details'"
                title="Show / hide details"
              >
                ▸
              </button>
              <div class="flex-1 min-w-0 cursor-pointer" @click="toggleKnowledgeExpanded(k.id)">
                <div class="text-body font-medium truncate" style="color: var(--semantic-text);">
                  {{ k.label || (k.content ? 'Inline knowledge' : basename(k.file_path)) }}
                </div>
                <div v-if="k.content" class="text-meta mt-0.5 flex items-center gap-1.5" style="color: var(--semantic-text-dim);">
                  <span
                    class="px-1.5 py-0.5 rounded shrink-0"
                    data-testid="agent-knowledge-inline-badge"
                    style="background: var(--semantic-card-bg); border: 1px solid var(--color-border);"
                  >Inline text</span>
                  <span v-if="!expandedKnowledge.has(k.id)" class="truncate" :title="k.content">{{ k.content.slice(0, 60) }}{{ k.content.length > 60 ? '…' : '' }}</span>
                </div>
                <div v-else class="text-meta font-mono truncate mt-0.5" style="color: var(--semantic-text-dim);" :title="k.file_path">
                  {{ k.file_path }}
                </div>
              </div>
              <button
                type="button"
                @click="emit('editKnowledge', k)"
                data-testid="agent-edit-knowledge"
                class="text-dense shrink-0 opacity-40 group-hover:opacity-100 transition-opacity px-1.5 py-0.5 rounded hover:bg-white/10"
                style="color: var(--semantic-text-muted);"
                :aria-label="`Edit ${k.label || basename(k.file_path)}`"
                title="Edit this knowledge entry"
              >
                ✎
              </button>
              <button
                type="button"
                @click="emit('removeKnowledge', k.id)"
                data-testid="agent-remove-knowledge"
                class="text-dense shrink-0 opacity-40 group-hover:opacity-100 transition-opacity px-1.5 py-0.5 rounded hover:bg-red-500/10"
                style="color: var(--color-red);"
                :aria-label="`Remove ${k.label || basename(k.file_path)}`"
                title="Remove this knowledge file"
              >
                ✕
              </button>
            </div>
            <!-- Expanded detail area -->
            <div
              v-if="expandedKnowledge.has(k.id)"
              data-testid="agent-knowledge-detail"
              class="mt-2 pt-2 border-t space-y-1.5"
              style="border-color: var(--color-border);"
            >
              <template v-if="k.content">
                <pre
                  data-testid="agent-knowledge-content-preview"
                  class="text-meta font-mono whitespace-pre-wrap break-words max-h-48 overflow-y-auto p-2 rounded"
                  style="background: var(--semantic-card-bg); color: var(--semantic-text-dim); border: 1px solid var(--color-border);"
                >{{ k.content }}</pre>
                <button
                  type="button"
                  @click="copyKnowledgeContent(k.content)"
                  data-testid="agent-knowledge-copy"
                  class="text-meta px-1.5 py-0.5 rounded font-medium hover:opacity-80"
                  style="background: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
                  title="Copy content to clipboard"
                >
                  ⧉ Copy
                </button>
              </template>
              <template v-else>
                <div class="text-meta font-mono break-all p-2 rounded" style="background: var(--semantic-card-bg); color: var(--semantic-text-dim); border: 1px solid var(--color-border);">
                  {{ k.file_path }}
                </div>
                <div class="text-meta" style="color: var(--semantic-text-dim);">
                  File-backed — the agent reads this file at chat start.
                </div>
              </template>
            </div>
          </li>
        </ul>
      </section>


      <div class="text-dense p-3 rounded-xl text-center" style="color: var(--semantic-text-dim); background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);">
        <UiIcon name="tip" size-class="w-3 h-3" /> Start a conversation from the sidebar. The system prompt is injected first, then knowledge files are loaded into context, and only the tools you've enabled will be available.
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Feature B1 (2026-08-22): 2-line description clamp. Expanded rows drop
   the class and render full height. -webkit-line-clamp is fine for the
   Chromium/Electron target. */
.agent-desc-clamped {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>

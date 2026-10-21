<!--
  KanbanToolsPanel — per-board tool allowlist panel for a kanban board.
  Mounted as a top-level tab body inside KanbanSettingsView at the
  route /app/kanban/:itemId/settings?tab=tools (iteration 2 of the
  2026-08-27 plan — split the Agent umbrella tab into Tools +
  Knowledge as separate top-level tabs).

  The component hosts ONLY the tools checkbox grid. Knowledge rows +
  system prompts were moved to KanbanKnowledgePanel.vue in the same
  iteration. Data shape + data-testid values are identical to the
  tools section that used to live in KanbanAgentSettings /
  KanbanAgentPanel.

  UI redesign (2026-08-28):
    - Two-row header: title + "X / Y enabled" summary chip + a
      full-width search input that filters the grid live.
    - Each tool row is a custom-checkbox card (NOT a native
      <input type=checkbox>) showing the tool name + its registry
      description, with a clearly tinted background when enabled
      (green-violet gradient border + filled checkbox).
    - "Use recommended starter set" preset button at the bottom
      when zero tools are enabled — lets the user bootstrap the
      config with a curated safe set (command, read_file, write_file).

  Public API:
    props: item ({ id, name? } | null), workspaceId (string)

  Data-load lifecycle:
    onMounted — fetches the agent-kanban bundle (or null on 404) +
    the tools registry. Toggling a tool calls enableAgentKanbanTool /
    disableAgentKanbanTool optimistically + revert-on-failure.

  Bootstrap contract (the unconfigured state):
    When the board has no agent_kanbans row yet, clicking a checkbox
    still calls enableAgentKanbanTool(kanbanId, toolName) — the
    backend auto-seeds the agent_kanbans row in
    agent_kanban_tools_create.zig. On success we re-fetch the bundle
    so config is populated and the unconfigured banner disappears.
    This is how a user FIRST configures a board from this UI.

-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  getAgentKanban,
  getAgentToolsRegistry,
  enableAgentKanbanTool,
  disableAgentKanbanTool,
  type AgentKanban,
} from '../../api'
import UiIcon from '../ui/UiIcon.vue'

const props = withDefaults(
  defineProps<{
    item: { id: string; name?: string } | null
    workspaceId?: string
  }>(),
  { workspaceId: '' },
)

const loading = ref(false)
const loadError = ref<string | null>(null)
// `config` is only needed to know "is there an agent_kanban row yet?" — toggles use
// `kanbanId.value` (NOT config.value.id) so first-enable from the unconfigured state still hits the
// backend, which auto-seeds the row in agent_kanban_tools_create.zig.
const config = ref<AgentKanban | null>(null)
const tools = ref<string[]>([])
const toolRegistry = ref<{ name: string; description: string }[]>([])

// Search filter — bound to the input at the top of the panel.
const searchQuery = ref('')

const kanbanId = computed(() => props.item?.id ?? '')

// Curated, safe-by-default starter set. Visible only when 0 tools are
// enabled — gives the user a one-click bootstrap.
// 'command' is the unified shell tool (bash/pwsh are not equipped).
const RECOMMENDED_TOOLS = ['command', 'read_file', 'write_file'] as const

const errText = (err: unknown): string => {
  const msg = err instanceof Error ? err.message : String(err)
  return msg.replace(/^API \d+:\s*/, '')
}

// Filtered tool list — case-insensitive substring match on name OR
// description. Search-empty = show everything.
const filteredTools = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) return toolRegistry.value
  return toolRegistry.value.filter(
    (t) => t.name.toLowerCase().includes(q) || t.description.toLowerCase().includes(q),
  )
})

const enabledCount = computed(() => tools.value.length)
const totalCount = computed(() => toolRegistry.value.length)

const load = async () => {
  if (!kanbanId.value) return
  loading.value = true
  loadError.value = null
  try {
    try {
      const reg = await getAgentToolsRegistry()
      toolRegistry.value = reg.tools
    } catch {
      toolRegistry.value = []
    }
    const data = await getAgentKanban(props.workspaceId ?? '', kanbanId.value)
    if (data) {
      config.value = data.agent_kanban
      tools.value = [...data.tools].sort()
    } else {
      config.value = null
      tools.value = []
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

const toolBusy = ref(false)
const isEnabled = (toolName: string) => tools.value.includes(toolName)

// Effective kanban id passed to the backend. We use the workspace_item id directly (NOT
// config.value.id) because the auto-seed path in agent_kanban_tools_create.zig inserts the
// agent_kanbans row keyed by workspace_item_id = kanban_id.
const effectiveKanbanId = () => kanbanId.value

const handleToggleTool = async (toolName: string) => {
  if (toolBusy.value) return
  const kid = effectiveKanbanId()
  if (!kid) return
  toolBusy.value = true
  const wasEnabled = isEnabled(toolName)
  if (wasEnabled) {
    tools.value = tools.value.filter((t) => t !== toolName)
  } else {
    tools.value = [...tools.value, toolName].sort()
  }
  try {
    if (wasEnabled) {
      await disableAgentKanbanTool(kid, toolName)
    } else {
      await enableAgentKanbanTool(kid, toolName)
    }
    // After a first-enable from the unconfigured state, refetch the bundle so `config` gets
    // populated and the unconfigured banner disappears. Cheap round-trip (one bundle read); saves a
    // page reload and surfaces the agent_kanbans row immediately.
    if (!wasEnabled && !config.value) {
      try {
        const data = await getAgentKanban(props.workspaceId ?? '', kid)
        if (data) {
          config.value = data.agent_kanban
          tools.value = [...data.tools].sort()
        }
      } catch {
        // Non-fatal — the optimistic flip still stands.
      }
    }
  } catch (err) {
    if (wasEnabled) {
      tools.value = [...tools.value, toolName].sort()
    } else {
      tools.value = tools.value.filter((t) => t !== toolName)
    }
    loadError.value = errText(err)
  } finally {
    toolBusy.value = false
  }
}

// Enable the curated starter set in one click. Only enabled-tools that
// are NOT in the registry get skipped (defensive — keeps the preset
// idempotent against future registry shape changes).
const handleApplyRecommended = async () => {
  if (toolBusy.value) return
  const kid = effectiveKanbanId()
  if (!kid) return
  toolBusy.value = true
  // Optimistic — flip on locally FIRST, then POST each. We sort after
  // the set so the visible state stays alphabetical.
  const registryNames = new Set(toolRegistry.value.map((t) => t.name))
  const toEnable = RECOMMENDED_TOOLS.filter(
    (n) => registryNames.has(n) && !tools.value.includes(n),
  )
  if (toEnable.length === 0) {
    toolBusy.value = false
    return
  }
  tools.value = [...tools.value, ...toEnable].sort()
  loadError.value = null
  try {
    await Promise.all(
      toEnable.map((n) => enableAgentKanbanTool(kid, n).catch((err) => {
        // Per-tool revert on failure (don't drop the whole preset).
        tools.value = tools.value.filter((t) => t !== n)
        loadError.value = errText(err)
      })),
    )
    if (!config.value) {
      try {
        const data = await getAgentKanban(props.workspaceId ?? '', kid)
        if (data) {
          config.value = data.agent_kanban
          tools.value = [...data.tools].sort()
        }
      } catch {
        // Non-fatal.
      }
    }
  } finally {
    toolBusy.value = false
  }
}
</script>

<template>
  <div data-testid="kanban-tools-panel" class="px-5 py-4 overflow-y-auto flex flex-col gap-3" style="max-height: calc(100vh - 14rem)">
    <!-- Top hard-load error (DB unreachable, registry absent, etc.) -->
    <div
      v-if="loadError && !config && enabledCount === 0 && !searchQuery"
      class="px-3 py-2 rounded-lg text-dense text-center"
      style="color: rgb(239, 68, 68); background-color: rgba(239, 68, 68, 0.08)"
      data-testid="kanban-tools-error"
    >
      {{ loadError }}
    </div>

    <!-- Header row: title + summary chip + search input -->
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <h3 class="text-body font-semibold flex items-center gap-2" style="color: var(--semantic-text)">
          <UiIcon name="tools" />
          <span>Available tools</span>
        </h3>
        <span
          v-if="!loading && totalCount > 0"
          class="text-dense px-2.5 py-1 rounded-full font-medium shrink-0"
          :style="
            enabledCount > 0
              ? 'background: linear-gradient(135deg, rgba(137,146,167,0.18), rgba(139,164,176,0.18)); color: var(--semantic-text); border: 1px solid rgba(137,146,167,0.4);'
              : 'background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);'
          "
          data-testid="kanban-tools-summary"
          :title="`${enabledCount} of ${totalCount} tools enabled`"
        >
          <span data-testid="kanban-tools-summary-enabled">{{ enabledCount }}</span>
          <span style="color: var(--semantic-text-dim)"> / </span>
          <span data-testid="kanban-tools-summary-total">{{ totalCount }}</span>
          <span class="ml-1 text-micro" style="color: var(--semantic-text-dim)">enabled</span>
        </span>
      </div>

      <input
        v-model="searchQuery"
        type="search"
        placeholder="Search tools by name or description…"
        data-testid="kanban-tools-search"
        class="w-full px-3 py-1.5 rounded-lg text-dense outline-none transition-all duration-200"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
      />
    </div>

    <!-- Body. Render the same grid layout for both configured +
         unconfigured — the only visual difference is the banner at
         the top. -->
    <div data-testid="kanban-agent-tools-panel" class="flex flex-col gap-1">
      <!-- Unconfigured banner (visible only when the agent_kanbans row
           hasn't been seeded yet — clicking any checkbox bootstraps it
           on the backend, see handleToggleTool). -->
      <div
        v-if="!config && !loading"
        class="px-3 py-2 rounded-lg text-dense flex items-start gap-2"
        style="
          color: var(--semantic-text-muted);
          background-color: rgba(137, 146, 167, 0.08);
          border: 1px dashed rgba(137, 146, 167, 0.35);
        "
        data-testid="kanban-tools-unconfigured"
      >
        <UiIcon name="tip" />
        <span>
          This board has no agent config yet. <strong>Tick the first tool</strong> below
          to create one — Knowledge &amp; System Prompts unlock once you've started.
        </span>
      </div>

      <!-- Loading skeleton row (rare path — first load before
           getAgentKanban + getAgentToolsRegistry land). -->
      <div
        v-if="loading && toolRegistry.length === 0"
        class="px-5 py-8 text-center text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="kanban-tools-loading"
      >
        Loading tool registry…
      </div>

      <!-- Empty registry — registry endpoint failed silently + no cached list. -->
      <p
        v-else-if="!loading && toolRegistry.length === 0"
        class="text-dense px-3 py-2 italic"
        style="color: var(--semantic-text-dim)"
        data-testid="kanban-agent-tools-empty"
      >
        Tool registry unavailable. Retry by re-opening this tab.
      </p>

      <!-- Filter-empty (user typed something that matched nothing). -->
      <p
        v-else-if="filteredTools.length === 0"
        class="text-dense px-3 py-2 italic text-center"
        style="color: var(--semantic-text-dim)"
        data-testid="kanban-tools-empty"
      >
        No tools match "<span style="color: var(--semantic-text)">{{ searchQuery }}</span>".
      </p>

      <!-- The actual grid. 2 cols on md+, 1 col on narrow. -->
      <div v-else class="grid grid-cols-1 md:grid-cols-2 gap-2">
        <button
          v-for="t in filteredTools"
          :key="t.name"
          type="button"
          class="text-left px-3 py-2.5 rounded-lg transition-all duration-150 flex items-start gap-2.5 focus:outline-none focus-visible:ring-2"
          :style="
            isEnabled(t.name)
              ? 'background: linear-gradient(135deg, rgba(137,146,167,0.14), rgba(139,164,176,0.10)); border: 1px solid rgba(137,146,167,0.55); color: var(--semantic-text); box-shadow: 0 1px 6px rgba(0,0,0,0.18);'
              : 'background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);'
          "
          :class="[toolBusy ? 'cursor-wait opacity-70' : 'cursor-pointer hover:opacity-90']"
          :disabled="toolBusy"
          :aria-pressed="isEnabled(t.name)"
          :data-testid="`kanban-agent-tool-${t.name}`"
          :title="t.description"
          @click="handleToggleTool(t.name)"
        >
          <!-- Custom checkbox square (NOT a native input — gives us
               full control over the visual state). The hidden input
               carries the data-testid selectors the existing tests
               use, but is `pointer-events: none` so the click
               registers on the wrapping button. -->
          <span
            class="shrink-0 mt-0.5 w-4 h-4 rounded flex items-center justify-center transition-colors"
            :style="
              isEnabled(t.name)
                ? 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); border: 1px solid var(--color-violet);'
                : 'background-color: transparent; border: 1.5px solid var(--color-border-light);'
            "
            aria-hidden="true"
          >
            <svg
              v-if="isEnabled(t.name)"
              class="w-3 h-3"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="3"
              stroke-linecap="round"
              stroke-linejoin="round"
              style="color: var(--color-bg, #1D1C19)"
            >
              <path d="M5 13l4 4L19 7" />
            </svg>
          </span>
          <!-- Carry-through of the existing test-id contract — a
               hidden checkbox lets the existing specs check the
               `checked` state via the .checked DOM property without
               rendering the native UI. -->
          <input
            type="checkbox"
            tabindex="-1"
            aria-hidden="true"
            class="sr-only"
            :checked="isEnabled(t.name)"
            :disabled="toolBusy"
            :data-testid="`kanban-agent-tool-check-${t.name}`"
            @click.stop="handleToggleTool(t.name)"
            @change="handleToggleTool(t.name)"
          />

          <!-- Name + description. Description truncates to 2 lines
               with ellipsis; full text surfaces in the button's
               native `title` attribute above. -->
          <div class="flex-1 min-w-0">
            <div
              class="text-dense font-medium truncate"
              :style="isEnabled(t.name) ? 'color: var(--semantic-text)' : 'color: var(--semantic-text-muted)'"
            >
              {{ t.name }}
            </div>
            <div
              class="text-meta mt-0.5 line-clamp-2 leading-snug"
              style="color: var(--semantic-text-dim)"
            >
              {{ t.description }}
            </div>
          </div>
        </button>
      </div>
    </div>

    <!-- Recommended starter set — visible only when zero tools are
         enabled AND the registry has actually loaded. Lets new users
         bootstrap the config with one click instead of picking each
         tool by hand. -->
    <div
      v-if="!loading && toolRegistry.length > 0 && enabledCount === 0"
      class="pt-3 mt-1 flex flex-col gap-2"
      style="border-top: 1px dashed var(--color-border)"
      data-testid="kanban-tools-preset-row"
    >
      <div class="flex items-center justify-between gap-2">
        <div class="text-dense" style="color: var(--semantic-text-dim)">
          <strong style="color: var(--semantic-text-muted)">Quick start:</strong>
          enable a safe starter set (command, read_file, write_file) — add more any time.
        </div>
        <button
          type="button"
          class="px-3 py-1.5 rounded-lg text-dense font-medium transition-all duration-200 shrink-0 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-90"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: var(--color-bg, #1D1C19);
          "
          :disabled="toolBusy"
          data-testid="kanban-tools-preset-recommended"
          @click="handleApplyRecommended"
        >
          ✨ Use recommended starter set
        </button>
      </div>
    </div>

    <!-- Non-fatal mutation error banner (after the first successful
         load but during toggles). -->
    <p
      v-if="loadError && (config || enabledCount > 0 || searchQuery)"
      class="text-dense px-3 py-2 rounded-lg"
      style="color: rgb(239, 68, 68); background-color: rgba(239, 68, 68, 0.08)"
      data-testid="kanban-tools-mutation-error"
    >
      {{ loadError }}
    </p>
  </div>
</template>

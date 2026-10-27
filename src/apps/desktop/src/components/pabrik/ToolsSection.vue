<script setup lang="ts">
/** ToolsSection — Tools tab in Pabrik settings. Renders the default tool checklist stored as
 * `config.json → "tools": [...]` (plan 2026-09-22-tools-menu-config-default-tools). */
import { computed, onMounted } from 'vue'

import { useAgentToolsStore, type AgentRegistryEntry } from '../../stores/agentTools'

const props = defineProps<{ modelValue: string[] | null }>()
const emit = defineEmits<{ change: [list: string[]] }>()

// Display selection while config.json has no `tools` key: the built-in seed lists from
// src/agentic_loop/tools_equipped.zig — DEFAULT_AGENT_TOOLS + DEFAULT_KANBAN_TOOLS
// (kanban_list, kanban_move_task).
const BUILTIN_DEFAULT_TOOLS: readonly string[] = [
  'command',
  'read_file',
  'write_file',
  'text_replace',
  'remove_file',
  'present_files',
  'list_directory',
  'search',
  'glob',
  // Web search. Both halves ship default-on: `list_web_search_providers` is how the agent discovers
  // what the user configured, and it answers with an explicit "none configured" envelope rather
  // than failing — so enabling them costs nothing until a `web_search` provider exists.
  'web_search',
  'list_web_search_providers',
  'update_plan',
  'get_plan',
  'ask_user',
  'save_memory',
  'load_memory',
  'read_workspace_session',
  // Starts or resumes a session agent, another workspace included. Default-on, like
  // `spawn_sub_agent`: handing work to another session is core agent behaviour.
  'run_session',
  // Workspace-scoped documents (Migration 095). Default-on: writing a note the user asked for is a
  // core agent behaviour, and both tools refuse cleanly outside a workspace-linked session, so
  // enabling them by default costs nothing.
  'add_document',
  'edit_document',
  // Read-only, and a prerequisite for every edit: `edit_document` replaces
  // the whole body, so the agent has to be able to FIND the row first.
  'search_documents',
  // `delete_document` is deliberately NOT in this preset. It is irreversible, so it belongs behind
  // a tick in the checklist rather than inside the set every new agent starts with. It still shows
  // up in the Documents group below, so it is one click away.
  'use_skill',
  'remove_skill',
  'add_skill',
  'edit_skill',
  'set_skill_metadata',
  'search_skills',
  'spawn_sub_agent',
  'list_agents',
  'used_tools',
  // Read-only introspection: where this session runs (cwd, git worktree, task)
  // and whether a run is in flight. Default-on, like `read_workspace_session`.
  'view_session',
  'search_tool',
  'view_tool',
  'use_tool',
  'kanban_list',
  'kanban_move_task',
]

// The 13 wireframe groups, rendered in this order; registry names not
// in GROUP_BY_TOOL fall into the trailing "Other" bucket.
const TOOL_GROUPS: readonly string[] = [
  'Files & shell',
  'Search',
  'Planning',
  'Memory & sessions',
  'Documents',
  'Skills',
  'Agents',
  'Interactive',
  'Progressive tool search',
  'Git',
  'Kanban',
  'Design',
  'Presentation & media',
  'MCP',
]

const GROUP_BY_TOOL: Record<string, string> = {
  command: 'Files & shell',
  read_file: 'Files & shell',
  write_file: 'Files & shell',
  text_replace: 'Files & shell',
  remove_file: 'Files & shell',
  list_directory: 'Files & shell',
  glob: 'Search',
  search: 'Search',
  web_search: 'Search',
  list_web_search_providers: 'Search',
  update_plan: 'Planning',
  get_plan: 'Planning',
  save_memory: 'Memory & sessions',
  load_memory: 'Memory & sessions',
  read_workspace_session: 'Memory & sessions',
  run_session: 'Memory & sessions',
  view_session: 'Memory & sessions',
  add_document: 'Documents',
  edit_document: 'Documents',
  search_documents: 'Documents',
  // Grouped with the other document tools so the irreversible one is one
  // tick away, but NOT in RECOMMENDED_TOOLS above — see the note there.
  delete_document: 'Documents',
  search_skills: 'Skills',
  use_skill: 'Skills',
  add_skill: 'Skills',
  edit_skill: 'Skills',
  remove_skill: 'Skills',
  spawn_sub_agent: 'Sub-agents',
  list_agents: 'Agents',
  used_tools: 'Progressive tool search',
  ask_user: 'Interactive',
  search_tool: 'Progressive tool search',
  view_tool: 'Progressive tool search',
  use_tool: 'Progressive tool search',
  set_git_worktree: 'Git',
  set_pull_request: 'Git',
  status_pull_request: 'Git',
  kanban_list: 'Kanban',
  kanban_move_task: 'Kanban',
  create_kanban_task: 'Kanban',
  set_design_page: 'Design',
  add_element: 'Design',
  update_element: 'Design',
  group_elements: 'Design',
  set_element_parent: 'Design',
  move_design_element: 'Design',
  move_element_to_page: 'Design',
  get_design_context: 'Design',
  preview_design_page: 'Design',
  present_files: 'Presentation & media',
  generate_image: 'Presentation & media',
  add_mcp_server: 'MCP',
}

// Hard invariants of the runtime (not user configuration):
// MAIN_AGENT_ONLY_NAMES never reach sub-agents, and the two kanban
// tools are the mode floor that is always re-added in kanban mode.
const MAIN_AGENT_ONLY = new Set(['spawn_sub_agent', 'ask_user', 'run_session'])
const MODE_FLOOR = new Set(['kanban_list', 'kanban_move_task'])

type Pill = { label: string; color: string }

function pillFor(name: string): Pill | null {
  if (MAIN_AGENT_ONLY.has(name)) return { label: 'main-agent only', color: 'var(--color-yellow)' }
  if (MODE_FLOOR.has(name)) return { label: 'mode floor', color: 'var(--color-violet)' }
  return null
}

const APPLY_CHIPS: readonly string[] = [
  'agent mode',
  'kanban mode',
  'design mode',
  'non-all (plain chat)',
]

const store = useAgentToolsStore()
onMounted(() => {
  void store.fetchRegistry()
})

const registry = computed(() => store.registry)

// null modelValue = "key absent from config.json" → built-in defaults.
const isDefaults = computed(() => props.modelValue === null)
const selectedSet = computed(() => new Set(props.modelValue ?? BUILTIN_DEFAULT_TOOLS))

const selectedCount = computed(
  () => registry.value.filter((t) => selectedSet.value.has(t.name)).length,
)

type ToolGroup = {
  name: string
  slug: string
  tools: Array<AgentRegistryEntry & { pill: Pill | null }>
  selectedCount: number
}

function slugify(groupName: string): string {
  return groupName
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

const grouped = computed<ToolGroup[]>(() => {
  const byGroup = new Map<string, Array<AgentRegistryEntry & { pill: Pill | null }>>()
  for (const tool of registry.value) {
    const groupName = GROUP_BY_TOOL[tool.name] ?? 'Other'
    const bucket = byGroup.get(groupName) ?? []
    bucket.push({ ...tool, pill: pillFor(tool.name) })
    byGroup.set(groupName, bucket)
  }
  const ordered = [
    ...TOOL_GROUPS,
    ...[...byGroup.keys()].filter((name) => !(TOOL_GROUPS as readonly string[]).includes(name)),
  ]
  return ordered
    .filter((name) => (byGroup.get(name)?.length ?? 0) > 0)
    .map((name) => {
      const tools = byGroup.get(name)!
      return {
        name,
        slug: slugify(name),
        tools,
        selectedCount: tools.filter((t) => selectedSet.value.has(t.name)).length,
      }
    })
})

function emitSelection(selection: Set<string>) {
  // Full explicit array, in registry order; names missing from the
  // registry are dropped so the saved list always validates server-side.
  emit(
    'change',
    registry.value.filter((t) => selection.has(t.name)).map((t) => t.name),
  )
}

function toggleTool(name: string) {
  const next = new Set(selectedSet.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  emitSelection(next)
}

function toggleGroup(group: ToolGroup) {
  const next = new Set(selectedSet.value)
  const allOn = group.tools.every((t) => next.has(t.name))
  for (const t of group.tools) {
    if (allOn) next.delete(t.name)
    else next.add(t.name)
  }
  emitSelection(next)
}

function selectAll() {
  emitSelection(new Set(registry.value.map((t) => t.name)))
}

function selectNone() {
  emitSelection(new Set())
}
</script>

<template>
  <div class="space-y-4" data-testid="tools-section">
    <!-- Description (wireframe copy) -->
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted)">
      Built-in tools the agent may use by default. Checked tools become the starting checklist for
      every <strong style="color: var(--semantic-text)">new agent and kanban</strong>, and the
      default set for <strong style="color: var(--semantic-text)">design</strong> and
      <strong style="color: var(--semantic-text)">plain-chat</strong> sessions. Saved to
      <code style="font-family: var(--font-mono)">config.json → "tools": [&hellip;]</code>. Existing
      agents keep their own per-item checklist.
    </p>

    <!-- "Applies to:" mode chips (wireframe copy) -->
    <div class="flex flex-wrap items-center gap-1.5">
      <span class="text-meta mr-1" style="color: var(--semantic-text-dim)">Applies to:</span>
      <span
        v-for="chip in APPLY_CHIPS"
        :key="chip"
        class="text-micro uppercase tracking-wide px-2 py-0.5 rounded-full border"
        style="border-color: var(--color-border); color: var(--color-violet)"
        >{{ chip }}</span
      >
      <span
        class="text-micro uppercase tracking-wide px-2 py-0.5 rounded-full border"
        style="border-color: var(--color-border); color: var(--semantic-text-dim)"
        >MCP tools stay on the MCP Servers tab</span
      >
    </div>

    <!-- Dim note while config.json has no `tools` key -->
    <p
      v-if="isDefaults"
      class="text-dense"
      style="color: var(--semantic-text-dim)"
      data-testid="defaults-note"
    >
      Built-in defaults — nothing is written to config.json until you change a tool.
    </p>

    <!-- Toolbar: summary + None / All -->
    <div class="flex items-center justify-between gap-4">
      <div class="text-dense" style="color: var(--semantic-text-muted)">
        <strong style="color: var(--semantic-text)">{{ selectedCount }}</strong>
        of {{ registry.length }} tools selected
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          data-testid="none-btn"
          @click="selectNone"
          class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
          style="
            border-color: var(--color-border);
            color: var(--semantic-text-muted);
            background-color: transparent;
          "
        >
          None
        </button>
        <button
          type="button"
          data-testid="all-btn"
          @click="selectAll"
          class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
          style="
            border-color: var(--color-violet);
            color: var(--color-violet);
            background-color: transparent;
          "
        >
          All
        </button>
      </div>
    </div>

    <!-- Registry states: the catalog is static, so loading/error are plain rows -->
    <div
      v-if="store.loading"
      class="text-dense py-3"
      style="color: var(--semantic-text-dim)"
      data-testid="registry-loading"
    >
      Loading tool registry…
    </div>
    <div
      v-else-if="store.error"
      class="text-dense py-3"
      style="color: var(--color-red)"
      data-testid="registry-error"
    >
      Could not load the tool registry: {{ store.error }}
    </div>

    <template v-else>
      <section
        v-for="group in grouped"
        :key="group.name"
        class="rounded-lg overflow-hidden"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
        :data-testid="`group-${group.slug}`"
      >
        <button
          type="button"
          class="w-full flex items-center justify-between px-4 py-2.5 cursor-pointer select-none transition-colors duration-150 hover:bg-[var(--semantic-hover-bg)]"
          style="border-bottom: 1px solid var(--color-border)"
          title="Toggle this group"
          @click="toggleGroup(group)"
        >
          <span
            class="text-meta font-semibold uppercase tracking-wider"
            style="color: var(--semantic-text-muted)"
            >{{ group.name }}</span
          >
          <span
            class="text-meta font-mono"
            :style="{
              color:
                group.selectedCount === group.tools.length
                  ? 'var(--color-green)'
                  : 'var(--semantic-text-dim)',
            }"
            >{{ group.selectedCount }}/{{ group.tools.length }}</span
          >
        </button>

        <label
          v-for="(tool, idx) in group.tools"
          :key="tool.name"
          class="flex items-start gap-3 px-4 py-2 cursor-pointer transition-colors duration-150 hover:bg-[var(--semantic-hover-bg)]"
          :style="idx > 0 ? 'border-top: 1px solid var(--color-border);' : undefined"
          :data-testid="`row-${tool.name}`"
        >
          <input
            type="checkbox"
            class="mt-1 w-4 h-4 cursor-pointer shrink-0"
            style="accent-color: var(--color-violet)"
            :checked="selectedSet.has(tool.name)"
            @change="toggleTool(tool.name)"
          />
          <div class="flex-1 min-w-0">
            <div class="text-dense font-mono" style="color: var(--semantic-text)">
              {{ tool.name
              }}<span
                v-if="tool.pill"
                class="ml-2 text-micro font-semibold uppercase tracking-wide px-1.5 h-4 inline-flex items-center rounded border align-middle"
                :style="{ color: tool.pill.color, borderColor: tool.pill.color }"
                >{{ tool.pill.label }}</span
              >
            </div>
            <div class="text-meta mt-0.5 leading-snug" style="color: var(--semantic-text-muted)">
              {{ tool.description }}
            </div>
          </div>
        </label>
      </section>
    </template>

    <!-- Why the checklist is trustworthy (wireframe footnote) -->
    <p class="text-meta leading-relaxed max-w-2xl" style="color: var(--semantic-text-dim)">
      Tool names and descriptions come from the existing
      <code style="font-family: var(--font-mono)">GET /api/agent-tools/registry</code>
      endpoint — the checklist cannot contain names the backend does not know. Pills:
      <span style="color: var(--color-yellow)">main-agent only</span> never reach sub-agents;
      <span style="color: var(--color-violet)">mode floor</span> tools are always re-added in kanban
      mode. Selection is written by the Settings autosave (<code
        style="font-family: var(--font-mono)"
        >PUT /api/config/pabrik</code
      >). Deep link: <code style="font-family: var(--font-mono)">/app/settings?section=tools</code>.
    </p>
  </div>
</template>

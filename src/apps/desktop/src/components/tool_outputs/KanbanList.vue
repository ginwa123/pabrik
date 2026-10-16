<!--
  KanbanList — tool output component for the `kanban_list` agent tool.

  Renders the XML envelope produced by `executeKanbanListToString` in
  `src/modules/agent/tools/kanban_list.zig`. The component is purely
  presentational: no API calls, no store mutations, no navigation.

  Three response shapes are possible:
    Success with columns + tasks:
      <kanban>
        <workspace_id>ws_...</workspace_id>
        <item_id>item_...</item_id>
        <columns>
          <column>
            <id>col_...</id><name>...</name>
            <position>0</position><task_count>3</task_count>
          </column>
          ...
        </columns>
        <tasks>
          <task>
            <id>task_...</id><name>...</name>
            <column_id>col_...</column_id>     (or empty when unassigned)
            <column_name>...</column_name>     (or empty when unassigned)
            <position>0</position>
          </task>
          ...
        </tasks>
      </kanban>
    Empty board (no columns): same shape but with <columns></columns>,
      <tasks></tasks>, and a sibling <hint> explaining the empty state.
    Error:
      <kanban><error>...</error></kanban>

  Header (always visible):
    `kanban_list → <N> columns · <M> tasks` (or `<M>/<total> tasks` when paginated) on success
    `kanban_list → error` on failure

  Expanded body (click header to toggle):
    Success: a column summary table (id + name + position + task_count)
      followed by a task table (id + name + column + position). Unassigned
      tasks (empty column_id) are grouped at the bottom and labelled
      "Unassigned". The empty-board hint is shown when the kanban exists
      but has zero columns.
    Error: a red block with the full error message.

  Style is consistent with the rest of the tool_outputs components
  (ReadFile, SetGitWorktree, SearchSkills): monospace, rounded-md,
  border + soft card bg, violet tool-name, ✗/✓ status indicators,
  expand/collapse `+`/`−` toggle on the right.
-->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { normalizeToolContent, parseKanbanList } from './_shared/toolOutputParser'

interface ColumnSummary {
  id: string
  name: string
  position: string
  task_count: number
}

interface TaskSummary {
  id: string
  name: string
  column_id: string
  column_name: string
  position: string
}

const props = defineProps<{
  content: unknown
  expanded?: boolean
  /** Tool-call args (XML from jsonArgsToXml, or JSON). Accepted so the
   *  dispatcher can thread call args uniformly; the list result carries
   *  no "unknown" fallback that needs it today. */
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)

const normalized = computed(() => normalizeToolContent(props.content))
const parsed = computed(() => {
  const p = parseKanbanList(normalized.value.data)
  if (normalized.value.error) {
    return { ...p, success: false, error: normalized.value.error }
  }
  return p
})

// Running: result envelope is still empty (no columns/tasks/error yet).
const isEmptyContent = (c: unknown): boolean =>
  // Running means the tool has not returned yet: the dispatcher passes an
  // empty-string placeholder. A completed-but-empty result object ({}) is
  // NOT running — it renders the empty/success state instead.
  c === null || c === undefined || (typeof c === 'string' && c.trim().length === 0)
const isRunning = computed(() => isEmptyContent(props.content))

// ---- Error / hint detection ------------------------------------------------
const errorMessage = computed(() => parsed.value.error)

const hintMessage = computed(() => parsed.value.hint)

const pagination = computed(() => {
  const total = parsed.value.totalCount
  if (total == null) return null
  return { total, hasMore: parsed.value.hasMore }
})

const isSuccess = computed(() => parsed.value.success)

// ---- Parsed columns + tasks ------------------------------------------------
const columns = computed((): ColumnSummary[] =>
  parsed.value.columns.map((c) => ({
    id: c.id,
    name: c.name,
    position: String(c.position),
    task_count: c.taskCount,
  })),
)

const tasks = computed((): TaskSummary[] =>
  parsed.value.tasks.map((t) => ({
    id: t.id,
    name: t.name,
    column_id: t.columnId ?? '',
    column_name: t.columnName ?? '',
    position: String(t.position),
  })),
)

const assignedTasks = computed(() => tasks.value.filter((t) => t.column_id.length > 0))
const unassignedTasks = computed(() => tasks.value.filter((t) => t.column_id.length === 0))

// ---- Derived display values ------------------------------------------------
const statusIndicator = computed(() => (isSuccess.value ? '✓' : '✗'))

const headerLabel = computed(() => {
  if (!isSuccess.value) return 'error'
  const c = columns.value.length
  const t = tasks.value.length
  const cols = `${c} column${c !== 1 ? 's' : ''}`
  const pg = pagination.value
  const tk =
    pg && pg.total !== t
      ? `${t}/${pg.total} task${pg.total !== 1 ? 's' : ''}`
      : `${t} task${t !== 1 ? 's' : ''}`
  return `${cols} · ${tk}`
})

const headerTitle = computed(() => {
  const ws = parsed.value.workspaceId ?? ''
  const item = parsed.value.itemId ?? ''
  return `workspace: ${ws} · item: ${item}`
})

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyId = async (e: Event, id: string) => {
  e.stopPropagation()
  if (id) {
    await navigator.clipboard.writeText(id)
  }
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-dense"
    :class="{ 'border-red-500/50 opacity-90': !isSuccess }"
    data-testid="kanban-list"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-dense">kanban_list</span>
      <span
        class="flex-1 truncate text-left text-[var(--semantic-text-muted)] text-dense"
        :title="headerTitle"
      >
        {{ headerLabel }}
      </span>

      <!-- Status indicator -->
      <span class="text-dense font-semibold" :class="isSuccess ? 'text-green-500' : 'text-red-500'">
        {{ statusIndicator }}
      </span>

      <!-- Live badge (tool call underway, envelope still empty) -->
      <span
        v-if="isRunning"
        data-testid="kanban-list-running"
        class="text-micro text-yellow-500 animate-pulse shrink-0"
      >
        running…
      </span>

      <!-- Toggle indicator -->
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-body">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <!-- Error message -->
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-dense">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>

      <!-- Empty board hint (kanban exists but has 0 columns) -->
      <div
        v-else-if="hintMessage"
        class="flex gap-2 px-2 py-1.5 text-[var(--semantic-text-dim)] text-dense italic border-b border-dashed border-[var(--color-border)]"
      >
        <span class="font-semibold shrink-0 not-italic">Hint:</span>
        <span class="whitespace-pre-wrap break-all">{{ hintMessage }}</span>
      </div>

      <!-- Success path: columns table + tasks table -->
      <template v-if="isSuccess">
        <!-- Columns section -->
        <div
          class="px-3 py-0.5 text-micro text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] border-b border-dashed border-[var(--color-border)]"
        >
          Columns ({{ columns.length }})
        </div>

        <div
          v-if="columns.length === 0"
          class="px-3 py-2 text-center text-[var(--semantic-text-muted)] text-dense italic"
        >
          No columns on this board.
        </div>

        <div v-else class="divide-y divide-[var(--color-border)]">
          <div
            v-for="col in columns"
            :key="col.id"
            class="group/row flex items-center gap-2 px-2 py-1 hover:bg-violet-500/5"
          >
            <span class="text-[var(--color-violet)] font-semibold shrink-0 w-12">
              #{{ col.position }}
            </span>
            <span class="flex-1 truncate text-[var(--semantic-text)] font-medium" :title="col.name">
              {{ col.name }}
            </span>
            <span
              class="text-[var(--semantic-text-dim)] text-micro truncate shrink-0 max-w-[10rem]"
              :title="col.id"
            >
              {{ col.id }}
            </span>
            <span
              class="shrink-0 px-1.5 py-0.5 rounded text-micro font-semibold"
              :class="
                col.task_count > 0
                  ? 'bg-violet-500/15 text-[var(--color-violet)]'
                  : 'bg-black/[0.05] text-[var(--semantic-text-muted)]'
              "
              :title="col.task_count + ' task' + (col.task_count !== 1 ? 's' : '')"
            >
              {{ col.task_count }}
            </span>
            <button
              v-if="col.id"
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover/row:opacity-100 hover:!text-violet-500 text-lead transition-opacity shrink-0"
              @click.stop="copyId($event, col.id)"
              title="Copy column id"
            >
              ⎘
            </button>
          </div>
        </div>

        <!-- Tasks section (only when there are tasks) -->
        <template v-if="tasks.length > 0">
          <div
            class="px-3 py-0.5 text-micro text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] border-y border-dashed border-[var(--color-border)]"
          >
            Tasks ({{ tasks.length }})
          </div>

          <div class="divide-y divide-[var(--color-border)]">
            <div
              v-for="task in assignedTasks"
              :key="task.id"
              class="group/row flex items-center gap-2 px-2 py-1 hover:bg-violet-500/5"
            >
              <span
                class="text-[var(--semantic-text-muted)] shrink-0 w-8 text-right text-micro"
              >
                #{{ task.position }}
              </span>
              <span
                class="flex-1 truncate text-[var(--semantic-text)] font-medium"
                :title="task.name"
              >
                {{ task.name }}
              </span>
              <span
                class="px-1.5 py-0.5 rounded text-micro font-medium truncate max-w-[8rem] shrink-0"
                :class="
                  task.column_name
                    ? 'bg-violet-500/15 text-[var(--color-violet)]'
                    : 'bg-black/[0.05] text-[var(--semantic-text-muted)]'
                "
                :title="task.column_name || 'Unassigned'"
              >
                {{ task.column_name || 'unassigned' }}
              </span>
              <button
                class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover/row:opacity-100 hover:!text-violet-500 text-lead transition-opacity shrink-0"
                @click.stop="copyId($event, task.id)"
                title="Copy task id"
              >
                ⎘
              </button>
            </div>

            <!-- Unassigned tasks get their own subsection -->
            <template v-if="unassignedTasks.length > 0">
              <div
                class="px-3 py-0.5 text-micro text-[var(--semantic-text-muted)] font-medium bg-black/[0.02] border-t border-dashed border-[var(--color-border)]"
              >
                Unassigned ({{ unassignedTasks.length }})
              </div>
              <div
                v-for="task in unassignedTasks"
                :key="task.id"
                class="group/row flex items-center gap-2 px-2 py-1 hover:bg-violet-500/5"
              >
                <span
                  class="text-[var(--semantic-text-muted)] shrink-0 w-8 text-right text-micro"
                >
                  #{{ task.position }}
                </span>
                <span
                  class="flex-1 truncate text-[var(--semantic-text)] font-medium"
                  :title="task.name"
                >
                  {{ task.name }}
                </span>
                <span
                  class="px-1.5 py-0.5 rounded text-micro font-medium bg-black/[0.05] text-[var(--semantic-text-muted)] shrink-0"
                >
                  unassigned
                </span>
                <button
                  class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover/row:opacity-100 hover:!text-violet-500 text-lead transition-opacity shrink-0"
                  @click.stop="copyId($event, task.id)"
                  title="Copy task id"
                >
                  ⎘
                </button>
              </div>
            </template>
          </div>
        </template>
      </template>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

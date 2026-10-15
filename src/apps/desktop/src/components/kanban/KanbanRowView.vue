<!--
  KanbanRowView — the "row mode" body of a kanban board.

  Renders the same data as the column board (<KanbanColumn> × N) but as
  a vertical list grouped by column: one collapsible section header per
  column (chevron + name + count badge + ⋮ menu) with compact 32 px
  task rows underneath.

  Column mode is the *moving* view (drag a card between columns); row
  mode is the *reading* view (scan the whole board, newest first per
  column). Both consume the same `columns` / `tasks` props and emit the
  same event set, so <KanbanView> reuses one pass-through block for
  both.

  No drag-and-drop here. Column mode's DnD is drop-into-a-column,
  append-to-end (KanbanColumn.handleDrop), and there is no
  intra-column reorder anywhere in the codebase — in a linear list the
  drop target is ambiguous, and a wrong guess silently reorders the
  user's board. Moving a task in row mode goes through the task detail
  panel, which already has a column picker.

  Public API:
    props:
      columns              KanbanColumn[]  (already position-sorted)
      tasks                Task[]          (the flat item.tasks array)
      workspaceId          string
      itemId               string
      cwd?                 string
      collapsedIds         string[]        (controlled by the parent,
                                           which owns localStorage)
      runAllBusyByColumn?  Record<string, boolean>
    emits: the same set <KanbanColumn> emits, plus `toggleCollapse`.
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import KanbanSortMenu from './KanbanSortMenu.vue'
import KanbanTaskRow, { type KanbanRowDensity } from './KanbanTaskRow.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import type { KanbanColumn, Task } from '../../stores/workspaces'

type SortField = 'position' | 'created_at' | 'updated_at' | 'name'
type SortDirection = 'asc' | 'desc'

const props = withDefaults(
  defineProps<{
    columns: KanbanColumn[]
    tasks: Task[]
    workspaceId: string
    itemId: string
    cwd?: string
    collapsedIds: string[]
    runAllBusyByColumn?: Record<string, boolean>
    stopAllBusyByColumn?: Record<string, boolean>
    /**      * Row height. `comfortable` is the two-line record (name + metadata); `compact` drops back to a
     * single line for boards with hundreds of tasks. The parent owns persistence — this component
     * only forwards it, so the preference survives a layout switch. */
    density?: KanbanRowDensity
  }>(),
  {
    cwd: '',
    runAllBusyByColumn: () => ({}),
    stopAllBusyByColumn: () => ({}),
    density: 'comfortable',
  },
)

const emit = defineEmits<{
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  requestRunAllAgents: [columnId: string]
  requestStopAllAgents: [columnId: string]
  sortChange: [
    {
      columnId: string
      sortBy: 'position' | 'created_at' | 'updated_at' | 'name'
      direction: 'asc' | 'desc'
    },
  ]
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  viewTaskDetail: [taskId: string]
  // Right-click "Run agent" from a row. Pass-through — the row emits
  // the task id and KanbanView makes the startAgentOnTask call.
  runAgent: [payload: { taskId: string }]
  toggleCollapse: [columnId: string]
}>()

const workspacesStore = useWorkspacesStore()

// ─── Grouping ──────────────────────────────────────────────────────────────
//
// Same filter <KanbanColumn> applies per column (cardsInColumn), hoisted
// so one pass produces every group. Order within a group is the wire
// order — the backend already returns each column's tasks in that
// column's own sort order (per-column sort independence).
const groups = computed(() =>
  props.columns.map((column) => ({
    column,
    rows: props.tasks.filter((t) => t.kanban_column_id === column.id),
  })),
)

const isCollapsed = (columnId: string): boolean => props.collapsedIds.includes(columnId)

// ─── Per-column pagination ─────────────────────────────────────────────────

// Mirrors <KanbanColumn>: the parent WorkspaceItem carries
// `columnPagination[colId]`, populated by fetchKanbanTasks and reset on
// SSE refetch / search / sort.
const parentItem = computed(() => {
  if (!props.workspaceId || !props.itemId) return null
  return (
    workspacesStore.workspaces
      .find((ws) => ws.id === props.workspaceId)
      ?.items.find((i) => i.id === props.itemId) ?? null
  )
})

const moreTasksAvailable = (columnId: string): boolean =>
  parentItem.value?.columnPagination?.[columnId]?.hasMore ?? false
const loadingMoreTasks = (columnId: string): boolean =>
  parentItem.value?.columnPagination?.[columnId]?.isLoading ?? false

// True while this column's FIRST page is in flight — see the note in
// KanbanColumn.vue. Gates the skeleton so the group does not render a
// false "No tasks yet" while the fetch is outstanding.
const isFirstPageLoading = (columnId: string): boolean =>
  workspacesStore.isFirstPageLoading(props.itemId, columnId)

const handleLoadMore = (columnId: string) => {
  if (!moreTasksAvailable(columnId)) return
  if (loadingMoreTasks(columnId)) return
  void workspacesStore.loadMoreTasksForColumn(props.workspaceId, props.itemId, columnId)
}

// ─── Per-group ⋮ menu ──────────────────────────────────────────────────────

// One open menu at a time, keyed by column id. Click-outside + Esc close
// it — same lifecycle as <KanbanColumn>'s menu.
const openMenuColumnId = ref<string | null>(null)
const menuRef = ref<HTMLElement | null>(null)

const toggleMenu = (columnId: string) => {
  openMenuColumnId.value = openMenuColumnId.value === columnId ? null : columnId
}
const closeMenu = () => {
  openMenuColumnId.value = null
}

const handleMenuRename = (columnId: string) => {
  closeMenu()
  emit('requestRenameColumn', columnId)
}
const handleMenuDelete = (columnId: string) => {
  closeMenu()
  emit('requestDeleteColumn', columnId)
}
const handleMenuRunAll = (columnId: string) => {
  closeMenu()
  emit('requestRunAllAgents', columnId)
}
const handleMenuStopAll = (columnId: string) => {
  closeMenu()
  emit('requestStopAllAgents', columnId)
}

// ─── Per-group sort modal ──────────────────────────────────────────────────
//
// The sort state is local to this view (the URL is the source of truth
// for persistence — <KanbanView> writes `?sorts=` on the sortChange
// emit). `sortModalColumnId` drives which group's modal is open; the
// modal reuses <KanbanSortMenu :show-trigger="false"> exactly like
// <KanbanColumn> does.
const sortModalColumnId = ref<string | null>(null)
const sortBy = ref<SortField>('position')
const direction = ref<SortDirection>('asc')

const handleMenuSort = (columnId: string) => {
  closeMenu()
  sortBy.value = 'position'
  direction.value = 'asc'
  sortModalColumnId.value = columnId
}

// <KanbanSortMenu> has no custom `click` emit — its `@click` is a native
// DOM listener that fires on ANY click inside the menu (that is how
// <KanbanColumn> uses it). The menu emits `update:sortBy` +
// `update:direction` together per pick (see handleSelect), so the update
// handlers below assign and emit exactly like the old watchers did: the
// first run clears `sortModalColumnId`, the second is a no-op.
const onSortPicked = () => {
  const columnId = sortModalColumnId.value
  if (!columnId) return
  emit('sortChange', {
    columnId,
    sortBy: sortBy.value,
    direction: direction.value,
  })
  sortModalColumnId.value = null
}

const onSortByUpdate = (v: SortField) => {
  sortBy.value = v
  onSortPicked()
}
const onDirectionUpdate = (v: SortDirection) => {
  direction.value = v
  onSortPicked()
}

const handleSortModalBackdrop = () => {
  sortModalColumnId.value = null
}

// ─── Inline column rename ──────────────────────────────────────────────────

// Single-clicking a group name starts an edit-in-place, matching
// <KanbanColumn>. Enter commits, Escape/blur cancels.
const renamingColumnId = ref<string | null>(null)
const renameValue = ref('')
// A `ref` inside a `v-for` collects an ARRAY of elements (one per
// rendered group), so this is typed as such and indexed by the group
// being renamed.
const renameInputs = ref<HTMLInputElement[]>([])

const startInlineRename = async (column: KanbanColumn) => {
  renamingColumnId.value = column.id
  renameValue.value = column.name
  await nextTick()
  const input = renameInputs.value[0]
  input?.focus()
  input?.select()
}

const commitInlineRename = () => {
  const columnId = renamingColumnId.value
  if (!columnId) return
  const next = renameValue.value.trim()
  const current = props.columns.find((c) => c.id === columnId)
  renamingColumnId.value = null
  if (!next || !current || next === current.name) return
  emit('renameColumn', { columnId, name: next })
}

const cancelInlineRename = () => {
  renamingColumnId.value = null
}

// ─── Menu dismissal ────────────────────────────────────────────────────────
const onDocumentClick = (event: MouseEvent) => {
  if (openMenuColumnId.value === null) return
  const target = event.target as Node | null
  if (menuRef.value && target && menuRef.value.contains(target)) return
  closeMenu()
}
const onDocumentKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    closeMenu()
    sortModalColumnId.value = null
  }
}

onMounted(() => {
  document.addEventListener('click', onDocumentClick)
  document.addEventListener('keydown', onDocumentKeydown)
})
onUnmounted(() => {
  document.removeEventListener('click', onDocumentClick)
  document.removeEventListener('keydown', onDocumentKeydown)
})
</script>

<template>
  <div
    class="flex-1 min-h-0 overflow-y-auto"
    style="scrollbar-width: thin"
    :data-testid="`kanban-view-${props.itemId}-rows`"
  >
    <!-- Board-level empty state. The column board has none (its empty
         state is per column); a linear list needs one because an empty
         board renders as a blank page otherwise. -->
    <div
      v-if="props.columns.length === 0"
      class="flex flex-col items-center justify-center gap-1 py-16 text-center"
      :data-testid="`kanban-view-${props.itemId}-rows-empty`"
    >
      <p class="text-body" style="color: var(--semantic-text-muted)">No columns on this board</p>
      <p class="text-dense" style="color: var(--semantic-text-dim)">
        Add one in Settings to start tracking tasks.
      </p>
    </div>

    <div v-else class="p-3 space-y-2">
      <section
        v-for="group in groups"
        :key="group.column.id"
        class="rounded-lg"
        style="border: 1px solid var(--color-border)"
        :data-kanban-row-group="group.column.id"
      >
        <!-- ─── Group header ─────────────────────────────────────────── -->
        <header
          class="flex items-center gap-2 px-3 py-2 border-b"
          style="border-color: var(--color-border)"
          :data-testid="`kanban-row-group-${group.column.id}-header`"
        >
          <button
            type="button"
            class="w-4 h-4 shrink-0 flex items-center justify-center rounded hover:opacity-80"
            style="color: var(--semantic-text-dim)"
            :aria-expanded="!isCollapsed(group.column.id)"
            :aria-label="
              isCollapsed(group.column.id)
                ? `Expand ${group.column.name}`
                : `Collapse ${group.column.name}`
            "
            :data-testid="`kanban-row-group-${group.column.id}-toggle`"
            @click="emit('toggleCollapse', group.column.id)"
          >
            <span
              class="text-micro transition-transform duration-200"
              :style="{
                transform: isCollapsed(group.column.id) ? 'rotate(0deg)' : 'rotate(90deg)',
              }"
              aria-hidden="true"
              >▶</span
            >
          </button>

          <input
            v-if="renamingColumnId === group.column.id"
            ref="renameInputs"
            v-model="renameValue"
            type="text"
            :data-testid="`kanban-row-group-${group.column.id}-rename-input`"
            class="flex-1 px-2 py-0.5 rounded text-body outline-none"
            style="
              background-color: var(--semantic-card-bg);
              border: 1px solid var(--color-border);
              color: var(--semantic-text);
            "
            @keyup.enter="commitInlineRename"
            @keyup.escape="cancelInlineRename"
            @blur="commitInlineRename"
          />
          <button
            v-else
            type="button"
            class="flex-1 text-left text-dense font-bold uppercase truncate hover:opacity-80"
            style="color: var(--semantic-text); letter-spacing: 0.07em"
            :data-testid="`kanban-row-group-${group.column.id}-name`"
            @click="startInlineRename(group.column)"
          >
            {{ group.column.name }}
          </button>

          <!-- Count badge. `+` marks "more pages exist" — the wire has no
               total_count, so this is loaded rows, not a true total
               (same limitation as the column board's badge).

               11px semibold on --semantic-text-muted (4.86:1) rather
               than 12px on --semantic-text-dim (2.79:1). A count is the
               fastest way to size a group before expanding it, so it
               has to clear the contrast bar. -->
          <span
            class="text-meta font-semibold px-2 py-0.5 rounded-full shrink-0"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-muted)"
            :data-testid="`kanban-row-group-${group.column.id}-count`"
          >
            {{ group.rows.length }}{{ moreTasksAvailable(group.column.id) ? '+' : '' }}
          </span>

          <div ref="menuRef" class="relative shrink-0">
            <button
              type="button"
              class="w-6 h-6 flex items-center justify-center rounded hover:opacity-80"
              style="color: var(--semantic-text-dim)"
              :data-testid="`kanban-row-group-${group.column.id}-menu-trigger`"
              @click.stop="toggleMenu(group.column.id)"
            >
              <span class="text-lead leading-none" aria-hidden="true">⋮</span>
            </button>
            <ul
              v-if="openMenuColumnId === group.column.id"
              class="absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-10 min-w-[120px]"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
              :data-testid="`kanban-row-group-${group.column.id}-menu`"
            >
              <li>
                <button
                  type="button"
                  class="w-full px-3 py-2 text-left text-body hover:opacity-80"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-row-group-${group.column.id}-menu-rename`"
                  @click="handleMenuRename(group.column.id)"
                >
                  Rename
                </button>
              </li>
              <li>
                <button
                  type="button"
                  class="w-full px-3 py-2 text-left text-body hover:opacity-80"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-row-group-${group.column.id}-menu-sort`"
                  @click="handleMenuSort(group.column.id)"
                >
                  Sort tasks…
                </button>
              </li>
              <li>
                <button
                  type="button"
                  class="w-full px-3 py-2 text-left text-body hover:opacity-80"
                  style="color: #ef4444"
                  :data-testid="`kanban-row-group-${group.column.id}-menu-delete`"
                  @click="handleMenuDelete(group.column.id)"
                >
                  Delete
                </button>
              </li>
              <li>
                <button
                  type="button"
                  class="w-full px-3 py-2 text-left text-body hover:opacity-80 disabled:opacity-50 disabled:cursor-not-allowed"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-row-group-${group.column.id}-menu-run-all`"
                  :disabled="!!props.runAllBusyByColumn[group.column.id]"
                  @click="handleMenuRunAll(group.column.id)"
                >
                  {{
                    props.runAllBusyByColumn[group.column.id]
                      ? 'Running all agents…'
                      : 'Run all agents'
                  }}
                </button>
              </li>
              <li>
                <button
                  type="button"
                  class="w-full px-3 py-2 text-left text-body hover:opacity-80 disabled:opacity-50 disabled:cursor-not-allowed"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-row-group-${group.column.id}-menu-stop-all`"
                  :disabled="!!props.stopAllBusyByColumn[group.column.id]"
                  @click="handleMenuStopAll(group.column.id)"
                >
                  {{
                    props.stopAllBusyByColumn[group.column.id]
                      ? 'Stopping all agents…'
                      : 'Stop all agents'
                  }}
                </button>
              </li>
            </ul>
          </div>
        </header>

        <!-- Column description. Not truncated: these strings carry the
             board's own rules ("only human puts the task here") and
             clipping them to one 11px line hides exactly the part
             that matters. `line-clamp-2` bounds the worst case. -->
        <p
          v-if="group.column.description"
          class="text-dense px-3 pt-1.5 pb-1.5 leading-relaxed line-clamp-2"
          style="color: var(--semantic-text-muted)"
          :title="group.column.description"
          :data-testid="`kanban-row-group-${group.column.id}-description`"
        >
          {{ group.column.description }}
        </p>

        <!-- ─── Rows ─────────────────────────────────────────────────── -->
        <div
          v-if="!isCollapsed(group.column.id)"
          class="ml-4 mr-2 mb-2 pl-2 border-l"
          style="border-color: var(--color-border)"
          :data-testid="`kanban-row-group-${group.column.id}-rows`"
        >
          <KanbanTaskRow
            v-for="task in group.rows"
            :key="task.id"
            :task="task"
            :workspace-id="props.workspaceId"
            :item-id="props.itemId"
            :cwd="props.cwd"
            :density="props.density"
            @select-task="(id) => emit('selectTask', id)"
            @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
            @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
            @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
            @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
            @view-task-detail="(id) => emit('viewTaskDetail', id)"
            @run-agent="(payload) => emit('runAgent', payload)"
          />

          <!-- First-page skeleton — holds the group's height while the
               column's page-1 fetch is in flight, so the group does not
               flash a false "No tasks yet". -->
          <div
            v-if="isFirstPageLoading(group.column.id)"
            class="space-y-1 py-1"
            :data-testid="`kanban-row-group-${group.column.id}-skeleton`"
            role="status"
            aria-label="Loading tasks"
          >
            <div
              v-for="n in 3"
              :key="n"
              class="h-9 rounded animate-pulse"
              style="background-color: var(--semantic-active-bg)"
            />
          </div>
          <div
            v-else-if="group.rows.length === 0"
            class="text-dense py-3"
            style="color: var(--semantic-text-dim)"
            :data-testid="`kanban-row-group-${group.column.id}-empty`"
          >
            No tasks yet
          </div>

          <button
            v-if="moreTasksAvailable(group.column.id) && group.rows.length > 0"
            type="button"
            :disabled="loadingMoreTasks(group.column.id)"
            class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded text-dense transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
            style="color: var(--semantic-text-dim)"
            :data-testid="`kanban-row-group-${group.column.id}-load-more`"
            @click="handleLoadMore(group.column.id)"
          >
            {{ loadingMoreTasks(group.column.id) ? 'Loading…' : 'Load more' }}
          </button>
        </div>
      </section>
    </div>

    <!-- ─── Per-group sort modal ──────────────────────────────────────── -->
    <div
      v-if="sortModalColumnId"
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5)"
      :data-testid="`kanban-row-group-${sortModalColumnId}-sort-modal`"
      @click.self="handleSortModalBackdrop"
    >
      <div
        class="rounded-lg shadow-2xl p-2 min-w-[240px] max-w-[90vw]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <KanbanSortMenu
          :sort-by="sortBy"
          :direction="direction"
          :show-trigger="false"
          @update:sort-by="onSortByUpdate"
          @update:direction="onDirectionUpdate"
        />
      </div>
    </div>
  </div>
</template>

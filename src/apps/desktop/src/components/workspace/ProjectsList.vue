<script setup lang="ts">
import { inject, onMounted, onUnmounted, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import type { Workspace, WorkspaceItem } from '../../stores/workspaces'

import WorkspaceItemComponent from './WorkspaceItem.vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
import * as api from '../../api'
import SidebarSkeleton from '../shell/SidebarSkeleton.vue'

// The single SELECTED workspace (header dropdown + Projects section). null = no workspace
// selected/exists — the template renders an empty-state hint instead of rows.
const props = defineProps<{
  workspace: Workspace | null
  activeWorkspaceItemId: string | null
}>()

// Inject processingState from App.vue (same key WorkspaceItem, ChatsList, ChatView consume). Keyed
// by task.id == session_id, so we scan a workspace's items→tasks for any key present in the map to
// know "is anything in this workspace currently busy with a worker?".
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const emit = defineEmits<{
  selectItem: [workspaceId: string, itemId: string]
  /** Ctrl/Cmd+click / middle click on an item row — re-emitted verbatim by Sidebar. */
  openItemInBackground: [
    payload: { workspaceId: string; itemId: string; name: string; itemType?: string },
  ]
  deleteItem: [workspaceId: string, itemId: string]
  requestAddItem: [workspaceId: string, itemType: string]
  addTask: [workspaceId: string, item: WorkspaceItem]
  selectTask: [taskId: string]
  openTaskInBackground: [
    payload: { workspaceId: string; itemId: string; itemType?: string; taskId: string },
  ]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): design
  // page events from <WorkspaceItem> (which forwards them from
  // <DesignPageRow>). Sidebar handles the actual store calls.
  selectDesignPage: [workspaceId: string, itemId: string, pageId: string]
  deleteDesignPage: [workspaceId: string, itemId: string, pageId: string]
  addDesignPage: [workspaceId: string, itemId: string]
  // NEW (rename-design-pages plan, 2026-08-06): ⋮ menu "Rename"
  // item forwards the page from WorkspaceItem → ProjectsList → Sidebar.
  // Sidebar opens RenameDesignPageModal + calls the store action.
  renameDesignPage: [workspaceId: string, itemId: string, pageId: string, currentName: string]
  openDesignPageInBackground: [payload: { workspaceId: string; itemId: string; pageId: string }]
  loadMoreTasks: [workspaceId: string, itemId: string]
  // Drag-and-drop reordering for items of a single workspace. Emitted on a successful drop with the
  // workspace id and the new top-to-bottom array of item IDs.
  reorderWorkspaceItems: [workspaceId: string, orderedItemIds: string[]]
  // NEW (pinned-tasks feature): pin/unpin and drag-reorder
  // of the pinned subset, forwarded from <WorkspaceItem>.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  reorderPinnedTasks: [workspaceId: string, itemId: string, orderedIds: string[]]
  // Right-click "Go to settings" from a workspace item row.
  // Forwarded verbatim to Sidebar, which routes per item_type.
  goToSettings: [payload: { workspaceId: string; itemId: string; itemType?: string }]
}>()

const sidebarStore = useSidebarStore()
const workspacesStore = useWorkspacesStore()
const activeAddMenu = ref<string | null>(null)

// Sidebar shows every project — the header search filter was removed (v2 sidebar UX: no search,
// always-visible actions, tighter indent). ─── Drag-and-drop state (item reordering)
// ──────────────────────────────── Scoped to a single workspace's items.
const draggingItemId = ref<string | null>(null)
const draggingItemWorkspaceId = ref<string | null>(null)
const dragOverItemId = ref<string | null>(null)
// When the cursor is hovering over `dragOverItemId`, this boolean records whether the cursor is in
// the BOTTOM half of that row (true) or the TOP half (false). The drop handler uses this to decide
// "insert after the target" vs "insert before the target" — see handleItemDrop for the index math.
const dragOverItemInsertAfter = ref(false)

// Close dropdown when clicking outside
const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as HTMLElement
  if (!target.closest('[data-workspace-menu]')) {
    activeAddMenu.value = null
  }
}

onMounted(() => {
  document.addEventListener('click', handleClickOutside)
})

onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const toggleProjectsSection = () => {
  sidebarStore.toggleProjectsExpanded()
}

const toggleAddMenu = (workspaceId: string) => {
  if (activeAddMenu.value === workspaceId) {
    activeAddMenu.value = null
  } else {
    activeAddMenu.value = workspaceId
  }
}

// Count of running workers across all items in this workspace (= session_id per Migration 052
// convention, same key `processingState` uses). The header shows a dot + "N running" text — never
// an elapsed time pill.
const runningTaskCountInWorkspace = (workspace: Workspace): number => {
  const state = processingState.value
  let n = 0
  for (const item of workspace.items) {
    const tasks = item.tasks
    if (!tasks || tasks.length === 0) continue
    for (const task of tasks) {
      if (state[task.id]) n += 1
    }
  }
  return n
}

const handleItemClick = (workspaceId: string, itemId: string) => {
  emit('selectItem', workspaceId, itemId)
}

const handleDeleteItem = (workspaceId: string, itemId: string) => {
  emit('deleteItem', workspaceId, itemId)
}

const handleAddItem = (workspaceId: string, itemType: string) => {
  activeAddMenu.value = null
  emit('requestAddItem', workspaceId, itemType)
}

const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  emit('addTask', workspaceId, item)
}

const handleSelectTask = (taskId: string) => {
  emit('selectTask', taskId)
}

const handleOpenTaskInBackground = (payload: {
  workspaceId: string
  itemId: string
  itemType?: string
  taskId: string
}) => {
  emit('openTaskInBackground', payload)
}

const handleDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  emit('deleteTask', workspaceId, itemId, taskId)
}

const handleRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  emit('renameTask', workspaceId, itemId, taskId, currentName)
}

const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  emit('loadMoreTasks', workspaceId, itemId)
}

// ─── Drag-and-drop handlers (item reordering) ────────────────────────────── Event delegation
// pattern: the handlers live on the per-workspace `<ul>` (so they're created once per workspace)
// but the draggable + data-* attributes live on each `<li>` inside `<WorkspaceItem>`.
const handleItemDragStart = (event: DragEvent) => {
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const itemId = li.dataset.itemId
  const workspaceId = li.dataset.workspaceId
  if (!itemId || !workspaceId) return
  draggingItemId.value = itemId
  draggingItemWorkspaceId.value = workspaceId
  if (event.dataTransfer) {
    // Dedicated MIME type so the item payload doesn't collide with workspace or pinned-task
    // payloads.
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-item-id', itemId)
  }
}

const handleItemDragOver = (event: DragEvent) => {
  // preventDefault on dragover is REQUIRED to allow the drop (HTML5
  // DnD spec). Without it, the browser cancels the drop with a
  // "not allowed" cursor.
  event.preventDefault()
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const itemId = li.dataset.itemId
  // Don't show the drop indicator on the source row itself (would
  // look like the drop happened on yourself).
  if (itemId && itemId !== draggingItemId.value) {
    if (dragOverItemId.value !== itemId) {
      dragOverItemId.value = itemId
    }
    // Update the "insert before / after" flag on EVERY dragover (not just when the target row
    // changes) — the cursor can move from the top to the bottom of the same row without
    // `dragOverItemId` updating, and the drop indicator should follow the cursor.
    const rect = li.getBoundingClientRect()
    dragOverItemInsertAfter.value = event.clientY > rect.top + rect.height / 2
  }
}

const handleItemDragLeave = (event: DragEvent) => {
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  // Only clear when the cursor actually leaves the row. The dragleave event fires when crossing
  // child elements too, so we check `relatedTarget` to see if the cursor is still inside the row.
  // If it is, do nothing.
  const related = event.relatedTarget as Node | null
  if (related && li.contains(related)) return
  if (dragOverItemId.value === li.dataset.itemId) {
    dragOverItemId.value = null
    dragOverItemInsertAfter.value = false
  }
}

const handleItemDrop = (event: DragEvent) => {
  event.preventDefault()
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const targetItemId = li.dataset.itemId
  const targetWorkspaceId = li.dataset.workspaceId
  if (!targetItemId || !targetWorkspaceId) return
  if (!draggingItemId.value || !draggingItemWorkspaceId.value) return
  // Cross-workspace drop: silently no-op. The user dragged an item from workspace A and dropped on
  // an item in workspace B. The plan scopes reorder to a single workspace; cross-workspace moves
  // are out of scope (would require a separate "moveItemToWorkspace" endpoint).
  if (targetWorkspaceId !== draggingItemWorkspaceId.value) return
  // Drop on self: no-op.
  if (targetItemId === draggingItemId.value) return
  // Find the workspace and compute the new order: take the current items, splice the source out,
  // then insert at a position computed from the cursor's Y offset within the target row. Top half =
  // insert BEFORE the target, bottom half = insert AFTER the target (Trello/Jira UX).
  const workspace = props.workspace
  if (!workspace || workspace.id !== targetWorkspaceId) return
  const items = workspace.items.slice()
  const fromIdx = items.findIndex((i) => i.id === draggingItemId.value)
  const toIdx = items.findIndex((i) => i.id === targetItemId)
  if (fromIdx === -1 || toIdx === -1) return
  const rect = li.getBoundingClientRect()
  // Rect.top + rect.height / 2 is the row's vertical midpoint.
  // clientY > midpoint → cursor in bottom half → insert after.
  // clientY <= midpoint → cursor in top half → insert before.
  const insertAfter = event.clientY > rect.top + rect.height / 2
  const removed = items.splice(fromIdx, 1)
  const moved = removed[0]
  if (!moved) return
  // After `splice(fromIdx, 1)`, items with index >= fromIdx have shifted left by 1 in the modified
  // array. The target row sits at `toIdx - 1` (if toIdx > fromIdx) or `toIdx` (if toIdx < fromIdx).
  const targetIdxInModified = toIdx > fromIdx ? toIdx - 1 : toIdx
  const insertAt = targetIdxInModified + (insertAfter ? 1 : 0)
  items.splice(insertAt, 0, moved)
  emit(
    'reorderWorkspaceItems',
    targetWorkspaceId,
    items.map((i) => i.id),
  )
}

const handleItemDragEnd = () => {
  // Always clear drag state on dragend, even if the drop was
  // cancelled. Without this, the source row stays dimmed forever.
  draggingItemId.value = null
  draggingItemWorkspaceId.value = null
  dragOverItemId.value = null
  dragOverItemInsertAfter.value = false
}
</script>

<template>
  <!-- No `h-full`: the sidebar <nav> is the scroll container, so this
       section is content-sized and grows only as far as its rows. -->
  <div class="flex flex-col">
    <!-- Section Header — chevron + title left; busy slider + add-item
         menu right. Workspace-level create/rename/delete + reorder
         moved to the header WorkspaceSwitcher (revamp plan:
-->
    <div class="relative shrink-0" data-workspace-menu>
      <div
        class="px-[var(--sb-gutter)] h-7 flex items-center shrink-0 border-b border-(--color-border)/40"
        data-testid="projects-section-header"
        @click="toggleProjectsSection"
      >
        <button
          class="flex items-center h-full min-w-0 flex-1 text-left transition-opacity hover:opacity-80"
          :aria-expanded="sidebarStore.projectsExpanded"
          aria-label="Projects"
          @click.stop="toggleProjectsSection"
        >
          <span
            class="w-[var(--sb-mark)] shrink-0 flex items-center text-meta transition-transform duration-200"
            :style="{
              transform: sidebarStore.projectsExpanded ? 'rotate(90deg)' : 'rotate(0deg)',
            }"
            style="color: var(--semantic-text-dim)"
            >▶</span
          >
          <span
            class="text-micro font-semibold uppercase tracking-[0.08em]"
            style="color: var(--semantic-text-dim)"
            >Projects</span
          >
          <span
            v-if="workspace"
            class="text-micro ml-1.5"
            style="
              color: var(--semantic-text-dim);
              opacity: 0.7;
              font-variant-numeric: tabular-nums;
            "
            data-testid="projects-count"
            >{{ workspace.items.length }}</span
          >
        </button>
        <!-- Running indicator: dot + count text only, never an elapsed
             pill. The elapsed pill lives on the owning row (ChatsList /
             WorkspaceItem) so one run renders one pill (wireframe R1). -->
        <span
          v-if="workspace && runningTaskCountInWorkspace(workspace) > 0"
          class="ml-auto flex items-center gap-1.5 shrink-0"
          data-testid="workspace-running-indicator"
          :title="runningTaskCountInWorkspace(workspace) + ' worker(s) running in this workspace'"
        >
          <span
            class="w-1.5 h-1.5 rounded-full shrink-0"
            style="background-color: var(--color-yellow)"
          />
          <span
            class="text-micro"
            style="
              color: var(--semantic-text-dim);
              opacity: 0.7;
              font-variant-numeric: tabular-nums;
            "
            >{{ runningTaskCountInWorkspace(workspace) }} running</span
          >
        </span>
        <button
          v-if="sidebarStore.projectsExpanded && workspace"
          class="ml-1.5 w-[var(--sb-hit)] h-[var(--sb-hit)] text-meta font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center shrink-0"
          style="color: var(--semantic-text-dim); opacity: 0.7"
          title="Add Item"
          aria-label="Add Item"
          data-testid="projects-add-item-button"
          @click.stop="toggleAddMenu(workspace.id)"
        >
          +
        </button>
      </div>
      <!-- Search removed (v2 sidebar UX) — every project is listed. -->
      <!-- Add-item menu — promoted from the old bottom "+ Add Item"
           row into the section header (revamp plan). -->
      <ul
        v-if="workspace && activeAddMenu === workspace.id"
        class="absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-50 min-w-[160px]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <li>
          <button
            disabled
            class="w-full px-3 py-2 text-left text-dense opacity-40 cursor-not-allowed"
            style="color: var(--semantic-text)"
            title="Coming soon"
            aria-disabled="true"
            data-testid="workspace-add-project-option"
          >
            Add Project
          </button>
        </li>
        <li>
          <button
            @click="handleAddItem(workspace.id, 'kanban')"
            class="w-full px-3 py-2 text-left text-dense hover:opacity-80 transition-opacity"
            style="color: var(--semantic-text)"
          >
            Add Kanban
          </button>
        </li>
        <!-- Design mode is paused: the option stays listed so the
             feature set is discoverable, but the button is disabled
             like "Add Project" so nobody can open AddDesignDialog.
             Re-enable by restoring the @click + classes below —
             Sidebar.handleAddItem still routes 'design'. -->
        <li>
          <button
            disabled
            class="w-full px-3 py-2 text-left text-dense opacity-40 cursor-not-allowed"
            style="color: var(--semantic-text)"
            title="Design mode is temporarily disabled"
            aria-disabled="true"
            data-testid="workspace-add-design-option"
          >
            Add Design (alpha)
          </button>
        </li>
        <!-- Agent Mode (plan 2026-08-15-agent-mode,
                   task_1786962724740_0): fourth dropdown option for
                   creating an Agent workspace item. Sidebar.handleAddItem
                   routes the 'agent' itemType to the new AddAgentDialog. -->
        <li>
          <button
            @click="handleAddItem(workspace.id, 'agent')"
            class="w-full px-3 py-2 text-left text-dense hover:opacity-80 transition-opacity"
            style="color: var(--semantic-text)"
            data-testid="workspace-add-agent-option"
          >
            Add Agent
          </button>
        </li>
        <!-- Workspace routines (Migration 084) are paused for the same
             reason as design mode: the option stays listed but the
             button is disabled so nobody can open
             AddRoutineItemDialog. Sidebar.handleAddItem still routes
             'routine'. -->
        <li>
          <button
            disabled
            class="w-full px-3 py-2 text-left text-dense opacity-40 cursor-not-allowed"
            style="color: var(--semantic-text)"
            title="Routines are temporarily disabled"
            aria-disabled="true"
            data-testid="workspace-add-routine-option"
          >
            Add Routine
          </button>
        </li>
      </ul>
    </div>

    <!-- Project rows. NOT a scroll container: the sidebar <nav> scrolls
         the whole panel. A second scroller here is what left Documents
         stranded at the bottom of a full-height Projects box. -->
    <div>
      <Transition name="collapse">
        <div v-show="sidebarStore.projectsExpanded">
          <!-- Projects loading skeleton — shown while the workspace tree
               is fetching and no items are painted yet. Keeps the section
               from flashing "No projects yet" on a slow boot. -->
          <SidebarSkeleton
            v-if="workspacesStore.isLoading && (!workspace || workspace.items.length === 0)"
            :rows="4"
            test-id="projects-loading-skeleton"
          />
          <ul
            v-if="workspace"
            class="space-y-0"
            @dragstart="handleItemDragStart"
            @dragover="handleItemDragOver"
            @dragleave="handleItemDragLeave"
            @drop="handleItemDrop"
            @dragend="handleItemDragEnd"
          >
            <WorkspaceItemComponent
              v-for="item in workspace.items"
              :key="item.id"
              :item="item"
              :is-active="activeWorkspaceItemId === item.id"
              :workspace-id="workspace.id"
              :is-item-dragging="draggingItemId === item.id"
              :is-item-drag-over="dragOverItemId === item.id && draggingItemId !== item.id"
              :is-item-drag-over-insert-after="dragOverItemInsertAfter"
              @click="handleItemClick(workspace.id, $event.id)"
              @open-item-in-background="emit('openItemInBackground', $event)"
              @go-to-settings="emit('goToSettings', $event)"
              @delete="handleDeleteItem(workspace.id, $event.id)"
              @add-task="handleAddTask(workspace.id, $event)"
              @select-task="handleSelectTask"
              @open-task-in-background="handleOpenTaskInBackground"
              @delete-task="handleDeleteTask"
              @rename-task="handleRenameTask"
              @load-more-tasks="handleLoadMoreTasks"
              @pin-task="(ws, item, task, isPinned) => emit('pinTask', ws, item, task, isPinned)"
              @reorder-pinned-tasks="
                (ws, item, orderedIds) => emit('reorderPinnedTasks', ws, item, orderedIds)
              "
              @select-design-page="(ws, item, pageId) => emit('selectDesignPage', ws, item, pageId)"
              @delete-design-page="(ws, item, pageId) => emit('deleteDesignPage', ws, item, pageId)"
              @add-design-page="(ws, item) => emit('addDesignPage', ws, item)"
              @rename-design-page="
                (ws, item, pageId, currentName) =>
                  emit('renameDesignPage', ws, item, pageId, currentName)
              "
              @open-design-page-in-background="emit('openDesignPageInBackground', $event)"
            />
            <li
              v-if="workspace.items.length === 0 && !workspacesStore.isLoading"
              class="px-[var(--sb-gutter)] py-2 text-micro"
              style="color: var(--semantic-text-dim)"
              data-testid="projects-empty"
            >
              No projects yet — use + above to add one.
            </li>
          </ul>
          <div
            v-else-if="!workspacesStore.isLoading"
            class="px-[var(--sb-gutter)] py-2 text-micro"
            style="color: var(--semantic-text-dim)"
            data-testid="projects-no-workspace"
          >
            No workspace selected.
          </div>
        </div>
      </Transition>
    </div>
  </div>
</template>

<style scoped>
/* Slide transition for workspace items */
.slide-enter-active,
.slide-leave-active {
  transition: all 0.2s ease-out;
  overflow: hidden;
}

.slide-enter-from,
.slide-leave-to {
  opacity: 0;
  max-height: 0;
  transform: translateY(-4px);
}

.slide-enter-to,
.slide-leave-from {
  opacity: 1;
  max-height: 500px;
}

/* Collapse transition for workspaces section */
.collapse-enter-active,
.collapse-leave-active {
  transition: all 0.2s ease-out;
  overflow: hidden;
}

.collapse-enter-from,
.collapse-leave-to {
  opacity: 0;
  max-height: 0;
}

.collapse-enter-to,
.collapse-leave-from {
  opacity: 1;
  max-height: 2000px;
}
</style>

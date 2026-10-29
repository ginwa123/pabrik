<!--
  DesignView — top-level design canvas for a `item_type === 'design'`
  workspace item.

  Layout (top → bottom):
    1. Top toolbar: item name + 💬 chat toggle.
    2. Main split (horizontal, flex row):
       - Canvas (flex-1, on the left): renders <DesignElement v-for>
         over an auto-grow viewport (the canvas div wraps the union
         bbox of all elements). The canvas-background feature (a fixed
         W × H page rectangle with drag/nudge clamps + snap-to-canvas-
         edges) has been removed; elements can be placed at any
         coordinates.
       - Right sidebar split (vertical):
         - <LayersPanel> on top
         - Resize handle (drag to resize)
         - <PropertiesPanel> on bottom
    3. Canvas header bar (inside the canvas, top): + Element button +
       active page name + element count.

  Page list is NOT rendered inside DesignView. Pages live in the
  workspace sidebar tree (see WorkspaceItem.vue's design-pages
  section). The canvas header bar shows the active page name so the
  user knows which page they're on.

  State (all local — no Pinia here, the parent AppLayout wires the
  store actions):
    pages           DesignPage[]   fetched on mount
    activePageId    string         defaults to first page
    elements        DesignElement[]  fetched on activePageId change
    selectedElementId  string | null
    rightSidebarWidth  number     persisted via localStorage

  On mount: the workspaces store's `fetchDesignPages` populates
  `designPagesByItemId[item.id]` (single source of truth shared
  with the sidebar tree). Default activePageId to the first page
  in the cache; fetch elements for that page via
  workspacesStore.fetchDesignElements.

  page activation (claimAndActivatePage): re-fetch elements for the new page.

  Canvas click on empty area clears selectedElementId. Escape keypress
  clears selectedElementId.

  Public API:
    props:
      item        WorkspaceItem    the parent design item
      workspaceId string            parent workspace id
      itemId      string            parent design item id (overrides item.id)
    emits:
      selectPage                          (tab change)
      selectElement, reorderElements      (layers)
      createElement, updateElement, deleteElement, htmlChanged  (mutations)
      openChat                            (top-right chat toggle)

  Page CRUD (add/delete) is OWNED by DesignView — the click handler
  calls the API directly and mutates `pages.value` so the tab strip
  updates without a re-fetch. The previous design bounced
  addPage/deletePage through AppLayout's handlers, which called the
  API but never told DesignView to refresh — leaving the user
  staring at stale tabs until they reloaded the page.

  Note: the canvas background feature has been removed
  so
  pages no longer have a visible W × H rectangle / enforced boundary
  in the canvas UI. The `design_pages.width` / `height` columns
  remain in the DB for backward compat; `setDesignPage` /
  `updateDesignPage` LLM tools still accept them as a "preferred
  export size".
-->
<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import DesignToolbar from './DesignToolbar.vue'
import DesignPagesPlaceholder from './DesignPagesPlaceholder.vue'
import DesignCanvasHeader from './DesignCanvasHeader.vue'
import DesignCanvas from './DesignCanvas.vue'
import DesignRightSidebar from './DesignRightSidebar.vue'
import DesignOverlays from './DesignOverlays.vue'
import { useWorkspacesStore, type WorkspaceItem } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useDesignHandlers } from '../../composables/useDesignHandlers'
import { useDesignHistory } from '../../composables/useDesignHistory'
import { useDesignContextMenu } from '../../composables/useDesignContextMenu'
import {
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the sidebar tree now owns the page list
  // via `designPagesByItemId` in the workspaces store.
  type DesignElement as DesignElementApi,
  type DesignPage,
} from '../../api'
import type { SnapGuide } from './useSnapGuides'
import { computeNextUntitledName } from './designPageNames'
import {
  LAYERS_DEFAULT_HEIGHT_RATIO, LAYERS_HEIGHT_KEY, SIDEBAR_DEFAULT_WIDTH,
  SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_WIDTH, SIDEBAR_WIDTH_KEY,
  ZOOM_DEFAULT, ZOOM_KEY_PREFIX, ZOOM_MAX, ZOOM_MIN,
} from './designViewStorage'
import { useDesignPanelResize } from './useDesignPanelResize'
import { useDesignPageSync } from './useDesignPageSync'
import { useDesignViewport } from './useDesignViewport'
import { useDesignKeyboard } from './useDesignKeyboard'
import { useDesignElementEvents, type DesignViewEmits } from './useDesignElementEvents'
import { useDesignContextActions } from './useDesignContextActions'
import { useDesignGroupDrag } from './useDesignGroupDrag'

const props = withDefaults(
  defineProps<{ item: WorkspaceItem; workspaceId?: string; itemId?: string }>(),
  { workspaceId: '', itemId: '' },
)

const emit = defineEmits<DesignViewEmits>()

const workspacesStore = useWorkspacesStore()

// Chunk 5: reorder dispatch. Calls the workspace store's reorderDesignElements action (which is
// itself a stub for now — the backend endpoint lands in a follow-up; the model function is already
// implemented in design_model.zig).
async function dispatchReorder(
  mode: 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward',
): Promise<void> {
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  if (selectedIds.value.size === 0) return
  // Undo/redo plan (Chunk 5): capture the current top-to-bottom z- order BEFORE the reorder call.
  // The composable's applyInverse for `reorder` is currently a no-op (no absolute-z-order endpoint
  // yet); this entry at least records what the order was at gesture time.
  const beforeOrder = elements.value.slice().sort((a, b) => b.z_index - a.z_index).map((e) => e.id)
  try {
    await workspacesStore.reorderDesignElements(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      mode,
      Array.from(selectedIds.value),
    )
    const afterOrder = elements.value.slice().sort((a, b) => b.z_index - a.z_index).map((e) => e.id)
    void history.captureReorder(beforeOrder, afterOrder)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError(`Failed to reorder (${mode}): ${message}`)
  }
}

// ─── Effective ids ─────────────────────────────────────────────────────
const effectiveItemId = computed(() => props.itemId || props.item.id)

// ─── Pages state ─────────────────────────────────────────────────────── NEW
// (design-pages-in-workspace-tree plan, 2026-08-06): pages now live in the workspaces store's
// `designPagesByItemId` cache, NOT in DesignView-local state.
const pages = computed<DesignPage[]>(() => {
  if (!effectiveItemId.value) return []
  return workspacesStore.designPagesByItemId[effectiveItemId.value] ?? []
})
// Single source of truth: the store's `activeDesignPageId` (set by the sidebar tree, the URL
// restore, and this component's page handlers). The computed setter routes every local assignment
// through the store, so sidebar-driven changes are visible here without a mirror.
const activePageId = computed<string>({
  get: () => workspacesStore.activeDesignPageId,
  set: (v: string) => {
    // Skip no-op sets: the old local-ref assignment only propagated (via its watcher) when the
    // value actually changed. Blindly writing would wipe a preset store page (e.g. loadPages
    // falling back to '' when the page list is empty — see AppLayout.createElement.spec.ts).
    const next = v ?? ''
    if (workspacesStore.activeDesignPageId !== next) workspacesStore.setActiveDesignPage(next)
  },
})
const pagesLoading = ref(false)
const pagesError = ref<string | null>(null)

const activePage = computed(() => pages.value.find((p) => p.id === activePageId.value) ?? null)

// ─── Elements state (mirrors item.design_elements) ─────────────────────
const elements = computed<DesignElementApi[]>(() => {
  // The store's `design_elements` array is the source of truth (other
  // tabs / SSE events update it). When it doesn't match the active
  // page id (because the user just switched pages), fall back to [].
  const stored = props.item.design_elements ?? []
  return stored.filter((e) => e.page_id === activePageId.value)
})

// ─── Selection state ─────────────────────────────────────────────────── Multi-select (Figma
// model). Empty Set = nothing selected. Plain click = exclusive select (replaces the selection);
// Shift+click = toggle membership (adds/removes without affecting the rest); Escape = clear all.
const selectedIds = ref<Set<string>>(new Set())

// Per-element nudge offset accumulator. The keyboard handler reads `el.x + offset[id].x` instead of
// `el.x` so consecutive ArrowLeft presses compose (the second press starts where the first one
// ended).
const nudgeOffsets = new Map<string, { x: number; y: number }>()

// PropertiesPanel only renders its single-element form when exactly one NEW (Chunk 6 of
// grouped-layers plan): useDesignHandlers composable providing `groupSelection` for the Cmd+G
// shortcut.
const designHandlers = useDesignHandlers({
  workspaceId: computed(() => props.workspaceId),
  itemId: computed(() => effectiveItemId.value),
  pageId: computed(() => activePageId.value),
  selectedIds,
})

// Undo/redo history composable (Chunk 3 of undo/redo plan). The
// composable reads activeWorkspaceId/itemId/pageId from the store
// directly, so we only need to pass the pageId ref.
const history = useDesignHistory(computed(() => activePageId.value))

// ─── Snap guides state ──────────────────────────────────────────────── While a drag is in
// progress, snap math (computeSnapDelta) emits the 1px violet alignment guides the user should see.
const snapGuides = ref<SnapGuide[]>([])

// ─── Preview/Edit mode ────────────────────────────────────────────────── When `isPreviewMode ===
// true`, each element's iframe gets `pointer-events: auto` (so the user can type into inputs /
// click buttons inside the rendered HTML) and the edit chrome (resize handles, selection outline.
const isPreviewMode = ref<boolean>(false)

const togglePreviewMode = (): void => {
  isPreviewMode.value = !isPreviewMode.value
  // Exiting Preview mode clears the selection so the user isn't surprised
  // by a now-visible resize handle on an element they didn't pick during
  // preview.
  if (!isPreviewMode.value) selectedIds.value = new Set()
}

// ─── Keyboard shortcuts ──────────────────────────────────────────────── True while the user is
// holding the Space bar. Drives the body's cursor (grab / grabbing) and gates the pointer-drag pan
// handler on the canvas container.
const isSpacePressed = ref(false)

const readStoredNumber = (key: string, fallback: number): number => {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return fallback
    const n = Number(raw)
    if (!Number.isFinite(n)) return fallback
    return n
  } catch {
    return fallback
  }
}
const writeStoredNumber = (key: string, n: number): void => {
  try {
    localStorage.setItem(key, String(n))
  } catch {
    /* no-op — localStorage may be disabled */
  }
}
const clamp = (n: number, min: number, max: number): number => Math.max(min, Math.min(max, n))
const loadSidebarWidth = (): number =>
  clamp(readStoredNumber(SIDEBAR_WIDTH_KEY, SIDEBAR_DEFAULT_WIDTH), SIDEBAR_MIN_WIDTH, SIDEBAR_MAX_WIDTH)
const saveSidebarWidth = (n: number): void => writeStoredNumber(SIDEBAR_WIDTH_KEY, n)
const loadLayersHeightRatio = (): number =>
  clamp(readStoredNumber(LAYERS_HEIGHT_KEY, LAYERS_DEFAULT_HEIGHT_RATIO), 0.15, 0.7)
const saveLayersHeightRatio = (n: number): void => writeStoredNumber(LAYERS_HEIGHT_KEY, n)
const loadZoom = (itemId: string): number =>
  clamp(readStoredNumber(ZOOM_KEY_PREFIX + itemId, ZOOM_DEFAULT), ZOOM_MIN, ZOOM_MAX)
const saveZoom = (itemId: string, n: number): void => writeStoredNumber(ZOOM_KEY_PREFIX + itemId, n)

// ─── Add element dialog state ──────────────────────────────────────────
const showAddElementDialog = ref(false)

// ─── Lifecycle: fetch pages on mount ──────────────────────────────────
const loadPages = async (): Promise<void> => {
  if (!props.workspaceId || !effectiveItemId.value) return
  pagesLoading.value = true
  pagesError.value = null
  try {
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the store owns the cache.
    // fetchDesignPages is idempotent via an in-flight guard, so concurrent calls (sidebar expand +
    // canvas mount) share the same network request.
    const fetched = await workspacesStore.fetchDesignPages(props.workspaceId, effectiveItemId.value)
    // Pick the active page in this priority: 1.
    const storePageId = workspacesStore.activeDesignPageId
    if (
      storePageId &&
      fetched.some((p) => p.id === storePageId) &&
      storePageId !== activePageId.value
    ) {
      choosePage(storePageId)
    } else if (!activePageId.value || !fetched.some((p) => p.id === activePageId.value)) {
      choosePage(fetched[0]?.id ?? '')
    } else {
      // Choice unchanged but the cursor may be stale (e.g. a sidebar
      // switch landed on this same page via the store): converge the
      // choice cursor and run effects only if the page is unclaimed.
      lastChosenPage.value = activePageId.value
      claimAndActivatePage()
    }
  } catch (err) {
    pagesError.value = err instanceof Error ? err.message : String(err)
    choosePage('')
  } finally {
    pagesLoading.value = false
  }
}

// Choice gate: replicates the old local-ref assignment semantics — the store (and the effects) only
// see a choice that differs from the last one this component made.
const lastChosenPage = ref('')

const canvasContextMenu = useDesignContextMenu()

const sharedDeps = {
  emit,
  workspaceId: computed(() => props.workspaceId),
  effectiveItemId,
  activePageId,
  pages,
  elements,
  selectedIds,
  nudgeOffsets,
  snapGuides,
  isPreviewMode,
  isSpacePressed,
  togglePreviewMode,
  showAddElementDialog,
  hasActivePage: computed(() => activePage.value !== null),
  designHandlers,
  history,
  contextMenu: canvasContextMenu,
  readZoom: loadZoom,
  writeZoom: saveZoom,
  readSidebarWidth: loadSidebarWidth,
  writeSidebarWidth: saveSidebarWidth,
  readLayersHeightRatio: loadLayersHeightRatio,
  writeLayersHeightRatio: saveLayersHeightRatio,
  dispatchReorder,
}

const {
  sidebarWidth,
  isSidebarResizing,
  startSidebarResize,
  layersHeightRatio,
  isLayersResizing,
  startLayersResize,
} = useDesignPanelResize(sharedDeps)

const { choosePage, claimAndActivatePage } = useDesignPageSync({ ...sharedDeps, lastChosenPage })

onMounted(() => {
  void loadPages()
})

const {
  zoom,
  zoomIn,
  zoomOut,
  zoomReset,
  zoomFit,
  handleCanvasClick,
  handleCanvasContextMenu,
  onPinchPointerDown,
  onPinchPointerMove,
  onPinchPointerEnd,
  handleCanvasWheel,
} = useDesignViewport(sharedDeps)

useDesignKeyboard({ ...sharedDeps, zoomFit })

const {
  handleElementToggle,
  handleElementUpdate,
  handleElementTranslate,
  handleElementResize,
  handleElementHtmlChanged,
  handleElementDelete,
  handleLayerSelect,
  handleLayerReparent,
} = useDesignElementEvents(sharedDeps)

const {
  handleDesignSelectAll,
  handleDesignContextMenuDelete,
  pagesForMoveDialog,
  elementNameForMoveDialog,
  moveToPageDialogVisible,
  handleDesignGroupFromContextMenu,
  handleDesignUngroupFromContextMenu,
  handleDesignLeaveGroupFromContextMenu,
  handleDesignMoveToPageFromContextMenu,
  handleDesignMoveToPageDialogSelect,
  handleDesignMoveToPageDialogClose,
} = useDesignContextActions(sharedDeps)

const { handleGroupDrag, handleDragStart, handleDragEnd } = useDesignGroupDrag(sharedDeps)

// Add a new design page. NEW (design-pages-in-workspace-tree plan, 2026-08-06): routes through the
// workspaces store so the sidebar tree's DesignPageRow array updates without a refetch.
const handleAddPage = async (): Promise<string | undefined> => {
  if (!props.workspaceId || !effectiveItemId.value) return undefined
  if (addPageInFlight.value) return undefined
  addPageInFlight.value = true
  try {
    const newPage = await workspacesStore.addDesignPage(
      props.workspaceId,
      effectiveItemId.value,
      computeNextUntitledName(pages.value),
    )
    if (newPage) {
      choosePage(newPage.id)
      return newPage.id
    }
    return undefined
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to add page', message)
    return undefined
  } finally {
    addPageInFlight.value = false
  }
}

// In-flight guard for the + Page button. Prevents a double-click from POSTing two duplicate pages
// back-to-back while the first request is still in flight. The disabled state is exposed via the +
// Page button's `:disabled` attribute so the user sees the lock.
const addPageInFlight = ref<boolean>(false)

// Exposed via `wrapper.vm.handleSelectPage` in DesignView.pageSync.spec.ts. Vue 3's `<script
// `<script setup>` auto-surfaces top-level bindings but eslint can't see the `vm.X` reflection path.
// eslint-disable-next-line @typescript-eslint/no-unused-vars
const handleSelectPage = (pageId: string): void => {
  // Mirror to the store first so AppLayout's design handlers (handleDesignUpdateElement /
  // handleDesignDeleteElement) always see the latest selection, even if the page-change
  // early-returns below.
  choosePage(pageId)
  // Re-emit for any external listener (AppLayout's @select-page
  // does nothing today, but the contract is preserved).
  emit('selectPage', pageId)
}

// Delete a design page. Routes through the store so the cache + `activeDesignPageId` fallback happen
// in one place.
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _handleDeletePage = async (pageId: string): Promise<void> => {
  if (!props.workspaceId || !effectiveItemId.value) return
  if (deletePageInFlight.value) return
  if (
    !confirm('Delete this page? This removes the page, its elements, and their on-disk HTML files.')
  ) {
    return
  }
  deletePageInFlight.value = true
  try {
    await workspacesStore.deleteDesignPage(props.workspaceId, effectiveItemId.value, pageId)
    // The store already picked the next-active page. choosePage
    // converges the choice cursor and runs the elements fetch when
    // the active page actually changed.
    choosePage(workspacesStore.activeDesignPageId)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to delete page', message)
  } finally {
    deletePageInFlight.value = false
  }
}

// In-flight guard for the per-page × button. Prevents a double-click from issuing two DELETE calls
// back-to-back while the first is in flight (which could fire two confirm dialogs in quick
// succession and confuse the user).
const deletePageInFlight = ref<boolean>(false)

// Keep the legacy handler name as an alias so LayersPanel's `@select="_handleElementSelect"` (a plain
// elementId with no additive flag) still works; LayersPanel reads Shift from the row click instead.
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _handleElementSelect = (elementId: string): void => {
  handleElementToggle(elementId, false)
}
</script>

<template>
  <section
    class="design-view flex flex-col h-full min-h-0"
    :data-design-item-id="item.id"
    data-testid="design-view"
  >
    <DesignToolbar :item-name="item.name" :page="activePage" @open-chat="emit('openChat', $event)" />

    <DesignPagesPlaceholder
      v-if="pagesLoading || pagesError || pages.length === 0"
      :loading="pagesLoading"
      :error="pagesError"
      @add-page="handleAddPage"
    />

    <!-- ─── Main split (canvas + right sidebar) ──────────────────── -->
    <div v-else class="flex-1 flex min-h-0">
      <!-- Canvas column -->
      <div class="flex-1 flex flex-col min-w-0 min-h-0" data-testid="design-canvas-column">
        <DesignCanvasHeader
          :is-preview-mode="isPreviewMode"
          :page-name="activePage ? activePage.name : null"
          :element-count="elements.length"
          :zoom="zoom"
          @add-element="showAddElementDialog = true"
          @toggle-preview="togglePreviewMode"
          @zoom-in="zoomIn"
          @zoom-out="zoomOut"
          @zoom-reset="zoomReset"
          @zoom-fit="zoomFit"
        />
        <DesignCanvas
          :elements="elements"
          :selected-ids="Array.from(selectedIds)"
          :zoom="zoom"
          :workspace-id="workspaceId"
          :item-id="itemId || item.id"
          :page-id="activePageId"
          :is-preview-mode="isPreviewMode"
          :snap-guides="snapGuides"
          @select="handleElementToggle($event.elementId, $event.additive)"
          @update="handleElementUpdate"
          @translate="handleElementTranslate"
          @resize="handleElementResize"
          @group-drag="handleGroupDrag"
          @drag-end="handleDragEnd"
          @drag-start="handleDragStart"
          @html-changed="handleElementHtmlChanged"
          @delete="handleElementDelete"
          @canvas-click="handleCanvasClick"
          @canvas-wheel="handleCanvasWheel"
          @pointer-down="onPinchPointerDown"
          @pointer-move="onPinchPointerMove"
          @pointer-end="onPinchPointerEnd"
          @context-menu="handleCanvasContextMenu"
        />
      </div>

      <DesignRightSidebar
        :elements="elements"
        :selected-ids="Array.from(selectedIds)"
        :is-preview-mode="isPreviewMode"
        :width="sidebarWidth"
        :layers-ratio="layersHeightRatio"
        :sidebar-resizing="isSidebarResizing"
        :layers-resizing="isLayersResizing"
        @select="handleLayerSelect"
        @reparent="handleLayerReparent"
        @reorder="emit('reorderElements', $event)"
        @delete="handleElementDelete"
        @group="handleDesignGroupFromContextMenu"
        @ungroup="handleDesignUngroupFromContextMenu"
        @leave-group="handleDesignLeaveGroupFromContextMenu"
        @select-all="handleDesignSelectAll"
        @bring-to-front="() => dispatchReorder('bring_to_front')"
        @bring-forward="() => dispatchReorder('bring_forward')"
        @send-backward="() => dispatchReorder('send_backward')"
        @send-to-back="() => dispatchReorder('send_to_back')"
        @context-menu-delete="handleDesignContextMenuDelete"
        @move-to-page="handleDesignMoveToPageFromContextMenu"
        @update="handleElementUpdate"
        @html-changed="handleElementHtmlChanged"
        @sidebar-resize-start="startSidebarResize"
        @layers-resize-start="startLayersResize"
      />
    </div>

    <DesignOverlays
      :show-add-element-dialog="showAddElementDialog"
      :active-page-id="activePageId"
      :elements="elements"
      :menu="canvasContextMenu.state.value"
      :move-to-page-visible="moveToPageDialogVisible"
      :element-name="elementNameForMoveDialog"
      :pages="pagesForMoveDialog"
      @create="emit('createElement', $event)"
      @close-add-element="showAddElementDialog = false"
      @group="handleDesignGroupFromContextMenu"
      @ungroup="handleDesignUngroupFromContextMenu"
      @leave-group="handleDesignLeaveGroupFromContextMenu"
      @select-all="handleDesignSelectAll"
      @move-to-page="handleDesignMoveToPageFromContextMenu"
      @bring-to-front="() => dispatchReorder('bring_to_front')"
      @bring-forward="() => dispatchReorder('bring_forward')"
      @send-backward="() => dispatchReorder('send_backward')"
      @send-to-back="() => dispatchReorder('send_to_back')"
      @context-menu-delete="handleDesignContextMenuDelete"
      @close-menu="canvasContextMenu.close()"
      @move-to-page-close="handleDesignMoveToPageDialogClose"
      @move-to-page-select="handleDesignMoveToPageDialogSelect"
    />
  </section>
</template>

<style scoped>
.design-view :deep(.overflow-auto)::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-track {
  background: transparent;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 4px;
}
.design-view :deep(.overflow-auto)::-webkit-scrollbar-thumb:hover {
  background: var(--semantic-text-dim);
}
</style>

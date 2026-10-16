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

  Note: the canvas background feature has been removed (plan
  docs/superpowers/plans/2026-07-29-remove-canvas-background.md), so
  pages no longer have a visible W × H rectangle / enforced boundary
  in the canvas UI. The `design_pages.width` / `height` columns
  remain in the DB for backward compat; `setDesignPage` /
  `updateDesignPage` LLM tools still accept them as a "preferred
  export size".
-->
<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import DesignElement from './DesignElement.vue'
import LayersPanel from './LayersPanel.vue'
import PropertiesPanel from './PropertiesPanel.vue'
import AddDesignElementDialog from './AddDesignElementDialog.vue'
import DesignContextMenu from './DesignContextMenu.vue'
import MoveToPageDialog from './MoveToPageDialog.vue'
import UiIcon from '../ui/UiIcon.vue'
import { useWorkspacesStore, type WorkspaceItem } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useDesignHandlers } from '../../composables/useDesignHandlers'
import { designLogger } from '../../helpers/designLogger'
import { useDesignHistory } from '../../composables/useDesignHistory'
import { useDesignContextMenu } from '../../composables/useDesignContextMenu'
import {
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the sidebar tree now owns the page list
  // via `designPagesByItemId` in the workspaces store.
  type DesignElement as DesignElementApi,
  type DesignPage,
} from '../../api'
import { computeSnapDelta, type SnapGuide } from './useSnapGuides'

const props = withDefaults(
  defineProps<{
    item: WorkspaceItem
    workspaceId?: string
    itemId?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
  },
)

const emit = defineEmits<{
  selectPage: [pageId: string]
  selectElement: [elementId: string]
  reorderElements: [orderedElementIds: string[]]
  createElement: [body: { name: string; type: DesignElementApi['type']; html: string }]
  updateElement: [elementId: string, patch: Partial<DesignElementApi>]
  // NEW (2026-08-06, split-move-resize plan) — typed translate/resize events.
  translateElement: [elementId: string, dx: number, dy: number]
  resizeElement: [elementId: string, patch: Partial<DesignElementApi>]
  deleteElement: [elementId: string]
  htmlChanged: [elementId: string, html: string]
  // NEW: top-right chat toggle.
  openChat: [
    payload: {
      pageId: string
      pageName: string
      workspaceItemTaskId: string
    },
  ]
}>()

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
  const beforeOrder = elements.value
    .slice()
    .sort((a, b) => b.z_index - a.z_index)
    .map((e) => e.id)
  try {
    await workspacesStore.reorderDesignElements(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      mode,
      Array.from(selectedIds.value),
    )
    const afterOrder = elements.value
      .slice()
      .sort((a, b) => b.z_index - a.z_index)
      .map((e) => e.id)
    void history.captureReorder(beforeOrder, afterOrder)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError(`Failed to reorder (${mode}): ${message}`)
  }
}

// Chunk 5: handlers for the 4 reorder + select-all + delete events emitted by the LayersPanel
// context menu (and the canvas's own DesignContextMenu).
function handleDesignSelectAll(): void {
  selectedIds.value = new Set(elements.value.map((e) => e.id))
}

async function handleDesignContextMenuDelete(targetIds: string[]): Promise<void> {
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  if (targetIds.length === 0) return
  if (!confirm(`Delete ${targetIds.length} element${targetIds.length === 1 ? '' : 's'}?`)) return
  // Undo/redo plan (Chunk 5): capture the deleted elements + their
  // HTML bodies BEFORE the deletion so undo can restore everything.
  // The composable's captureDelete is async (fetches HTML bodies).
  const deletedElements = targetIds
    .map((id) => {
      const el = elements.value.find((e) => e.id === id)
      if (!el) return null
      return { element: { ...el }, htmlBody: null as string | null }
    })
    .filter((e): e is { element: DesignElementApi; htmlBody: string | null } => e !== null)
  void history.captureDelete(deletedElements)
  for (const id of targetIds) {
    void workspacesStore.deleteDesignElement(
      props.workspaceId,
      effectiveItemId.value,
      activePageId.value,
      id,
    )
  }
  // Drop any deleted ids from the local selection Set so the
  // remaining selection (if any) stays intact.
  const deleted = new Set(targetIds)
  const next = new Set<string>()
  for (const id of selectedIds.value) {
    if (!deleted.has(id)) next.add(id)
  }
  selectedIds.value = next
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

// NEW (2026-08-06, design-move-to-page plan, Chunk 8): pass-through computed properties for the
// MoveToPageDialog. `pages` is already scoped to `effectiveItemId.value`; we just need the selected
// element's name (looked up from the local elements list).
const pagesForMoveDialog = computed<DesignPage[]>(() => pages.value)
const elementNameForMoveDialog = computed<string>(() => {
  const id = moveToPageDialogElementId.value
  if (!id) return ''
  const el = elements.value.find((e) => e.id === id)
  return el?.name ?? id
})

// ─── Elements state (mirrors item.design_elements) ─────────────────────
const elements = computed<DesignElementApi[]>(() => {
  // The store's `design_elements` array is the source of truth (other
  // tabs / SSE events update it). When it doesn't match the active
  // page id (because the user just switched pages), fall back to [].
  const stored = props.item.design_elements ?? []
  return stored.filter((e) => e.page_id === activePageId.value)
})

// True while the active page's element fetch is in flight. Without it
// the canvas renders "Click + Element to add your first element" during
// the fetch — a false statement about the page's data.
const isElementsLoading = computed(() => {
  const itemId = effectiveItemId.value
  if (!itemId || !activePageId.value) return false
  return workspacesStore.isDesignElementsLoading(itemId, activePageId.value)
})

// ─── Selection state ─────────────────────────────────────────────────── Multi-select (Figma
// model). Empty Set = nothing selected. Plain click = exclusive select (replaces the selection);
// Shift+click = toggle membership (adds/removes without affecting the rest); Escape = clear all.
const selectedIds = ref<Set<string>>(new Set())

// Per-element nudge offset accumulator. The keyboard handler reads `el.x + offset[id].x` instead of
// `el.x` so consecutive ArrowLeft presses compose (the second press starts where the first one
// ended).
const nudgeOffsets = new Map<string, { x: number; y: number }>()

const activeElements = computed<DesignElementApi[]>(() => {
  return elements.value.filter((e) => selectedIds.value.has(e.id))
})

const isSingleSelect = computed(() => selectedIds.value.size === 1)
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

// ─── Preview/Edit mode ──────────────────────────────────────────────────
//
// When `isPreviewMode === true`, each element's iframe gets
// `pointer-events: auto` (so the user can type into inputs / click
// buttons inside the rendered HTML) and the edit chrome (resize
// handles, selection outline, drag handler) is suppressed. State is
// transient — no localStorage, no backend roundtrip — a "play the
// mockup" affordance. Default false.
// Keyboard: - Cmd/Ctrl+P: toggle Preview ↔ Edit - Esc: exit Preview (return to Edit)
const isPreviewMode = ref<boolean>(false)

const togglePreviewMode = (): void => {
  isPreviewMode.value = !isPreviewMode.value
  // Exiting Preview mode clears the selection so the user isn't surprised
  // by a now-visible resize handle on an element they didn't pick during
  // preview.
  if (!isPreviewMode.value) selectedIds.value = new Set()
}

// ─── Right sidebar width (drag-resize handle) ──────────────────────────
const SIDEBAR_WIDTH_KEY = 'design-view-sidebar-width'
const SIDEBAR_DEFAULT_WIDTH = 320
const SIDEBAR_MIN_WIDTH = 220
const SIDEBAR_MAX_WIDTH = 600

const loadSidebarWidth = (): number => {
  try {
    const raw = localStorage.getItem(SIDEBAR_WIDTH_KEY)
    if (!raw) return SIDEBAR_DEFAULT_WIDTH
    const n = Number(raw)
    if (!Number.isFinite(n)) return SIDEBAR_DEFAULT_WIDTH
    return Math.max(SIDEBAR_MIN_WIDTH, Math.min(SIDEBAR_MAX_WIDTH, n))
  } catch {
    return SIDEBAR_DEFAULT_WIDTH
  }
}
const saveSidebarWidth = (n: number): void => {
  try {
    localStorage.setItem(SIDEBAR_WIDTH_KEY, String(n))
  } catch {
    /* no-op — localStorage may be disabled */
  }
}

const sidebarWidth = ref<number>(loadSidebarWidth())
const isSidebarResizing = ref(false)

const startSidebarResize = (event: MouseEvent): void => {
  event.preventDefault()
  const startX = event.clientX
  const startWidth = sidebarWidth.value
  isSidebarResizing.value = true
  document.body.style.cursor = 'col-resize'
  document.body.style.userSelect = 'none'

  const onMove = (e: MouseEvent): void => {
    const dx = startX - e.clientX
    const next = Math.max(SIDEBAR_MIN_WIDTH, Math.min(SIDEBAR_MAX_WIDTH, startWidth + dx))
    sidebarWidth.value = next
  }
  const onUp = (): void => {
    isSidebarResizing.value = false
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
    saveSidebarWidth(sidebarWidth.value)
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }
  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

// ─── Vertical split between Layers and Properties (within sidebar) ─────
const LAYERS_HEIGHT_KEY = 'design-view-layers-height'
const LAYERS_DEFAULT_HEIGHT_RATIO = 0.4

const loadLayersHeightRatio = (): number => {
  try {
    const raw = localStorage.getItem(LAYERS_HEIGHT_KEY)
    if (!raw) return LAYERS_DEFAULT_HEIGHT_RATIO
    const n = Number(raw)
    if (!Number.isFinite(n)) return LAYERS_DEFAULT_HEIGHT_RATIO
    return Math.max(0.15, Math.min(0.7, n))
  } catch {
    return LAYERS_DEFAULT_HEIGHT_RATIO
  }
}
const saveLayersHeightRatio = (n: number): void => {
  try {
    localStorage.setItem(LAYERS_HEIGHT_KEY, String(n))
  } catch {
    /* no-op */
  }
}

const layersHeightRatio = ref<number>(loadLayersHeightRatio())
const isLayersResizing = ref(false)

const startLayersResize = (event: MouseEvent): void => {
  event.preventDefault()
  const sidebarEl = (event.currentTarget as HTMLElement | null)?.parentElement
  if (!sidebarEl) return
  const startY = event.clientY
  const startRatio = layersHeightRatio.value
  const sidebarHeight = sidebarEl.getBoundingClientRect().height
  isLayersResizing.value = true
  document.body.style.cursor = 'row-resize'
  document.body.style.userSelect = 'none'

  const onMove = (e: MouseEvent): void => {
    const dy = e.clientY - startY
    const ratio = startRatio + dy / sidebarHeight
    layersHeightRatio.value = Math.max(0.15, Math.min(0.7, ratio))
  }
  const onUp = (): void => {
    isLayersResizing.value = false
    document.body.style.cursor = ''
    document.body.style.userSelect = ''
    saveLayersHeightRatio(layersHeightRatio.value)
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', onUp)
  }
  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseup', onUp)
}

// ─── Add element dialog state ──────────────────────────────────────────
const showAddElementDialog = ref(false)
const openAddElementDialog = (): void => {
  showAddElementDialog.value = true
}

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

onMounted(() => {
  void loadPages()
})

// Page activation (mirrors KanbanView's loadColumns pattern). Runs the side effects of a page
// change: clear the selection (it belongs to the old page), drop cached nudge offsets, and fetch
// the new page's elements.
const activatePage = (pageId: string): void => {
  selectedIds.value = new Set()
  // Nudge offsets are per-element; fresh page means every cached
  // offset is for an element that no longer exists.
  nudgeOffsets.clear()
  if (!pageId) return
  if (!props.workspaceId || !effectiveItemId.value) return
  void workspacesStore.fetchDesignElements(props.workspaceId, effectiveItemId.value, pageId)
}
// Effect cursor: the page the effects last ran for. Local page changes
// claim it synchronously (so the update guard below stays silent);
// sidebar-tree store changes arrive via the guard.
const prevActivePage = ref(activePageId.value)
const claimAndActivatePage = (): void => {
  const pageId = activePageId.value
  if (pageId === prevActivePage.value) return
  prevActivePage.value = pageId
  activatePage(pageId)
}
// Choice gate: replicates the old local-ref assignment semantics — the store (and the effects) only
// see a choice that differs from the last one this component made.
const lastChosenPage = ref('')
const choosePage = (choice: string): void => {
  if (choice === lastChosenPage.value) return
  lastChosenPage.value = choice
  activePageId.value = choice
  claimAndActivatePage()
}
onMounted(() => {
  prevActivePage.value = activePageId.value
})
onUpdated(() => {
  claimAndActivatePage()
})

// ─── Keyboard shortcuts ──────────────────────────────────────────────── True while the user is
// holding the Space bar. Drives the body's cursor (grab / grabbing) and gates the pointer-drag pan
// handler on the canvas container.
const isSpacePressed = ref(false)

const handleKeydown = (event: KeyboardEvent): void => {
  // Skip when the user is typing in an input/textarea/contenteditable
  // — don't steal keys from the W×H inputs, the PropertiesPanel
  // form fields, etc.
  const target = event.target as HTMLElement | null
  if (
    target &&
    (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)
  ) {
    return
  }

  // Space held (no Ctrl/Cmd/Alt/Shift — those are bound to other shortcuts, and Alt+Space is the
  // window-menu shortcut on Linux/macOS). Plain Space should NOT scroll the page when the design
  // view is mounted — that's the browser default we override here.
  if (event.key === ' ' && !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey) {
    if (!isSpacePressed.value) {
      isSpacePressed.value = true
      document.body.style.cursor = 'grab'
    }
    event.preventDefault()
    return
  }

  if (event.key === 'Escape') {
    // Esc exits Preview first (more useful than clearing selection
    // — the user is trying to get back to editing). Only clear the
    // selection if we're already in Edit mode.
    if (isPreviewMode.value) {
      togglePreviewMode()
      return
    }
    selectedIds.value = new Set()
    // Also close the canvas context menu (Chunk 4) and the
    // add-element dialog if it's open.
    canvasContextMenu.close()
    if (showAddElementDialog.value) {
      showAddElementDialog.value = false
    }
    return
  }

  // Chunk 4: Cmd/Ctrl+A → Select all (Figma convention).
  // Handles BOTH Mac (metaKey) and Linux/Windows (ctrlKey).
  if (
    (event.key === 'a' || event.key === 'A') &&
    (event.ctrlKey || event.metaKey) &&
    !event.shiftKey &&
    !event.altKey
  ) {
    event.preventDefault()
    selectedIds.value = new Set(elements.value.map((e) => e.id))
    return
  }

  // Chunk 4: Cmd/Ctrl+] (bring forward) and Cmd/Ctrl+Shift+] (bring to front). Both gate on
  // selection.size >= 1. The actual reorder call lives in `workspacesStore.reorderDesignElements`,
  // which Chunk 5 introduces — until then the shortcut fires the stub that no-ops with a warning.
  if (event.key === ']' && (event.ctrlKey || event.metaKey) && !event.altKey) {
    event.preventDefault()
    if (event.shiftKey) {
      void dispatchReorder('bring_to_front')
    } else {
      void dispatchReorder('bring_forward')
    }
    return
  }

  // Chunk 4: Cmd/Ctrl+[ (send backward) and Cmd/Ctrl+Shift+[
  // (send to back).
  if (event.key === '[' && (event.ctrlKey || event.metaKey) && !event.altKey) {
    event.preventDefault()
    if (event.shiftKey) {
      void dispatchReorder('send_to_back')
    } else {
      void dispatchReorder('send_backward')
    }
    return
  }

  // Chunk 4: Backspace / Delete → delete current selection.
  if (
    (event.key === 'Backspace' || event.key === 'Delete') &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    !event.shiftKey
  ) {
    event.preventDefault()
    if (selectedIds.value.size === 0) return
    const count = selectedIds.value.size
    if (!confirm(`Delete ${count} element${count === 1 ? '' : 's'}?`)) return
    if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
    // Undo/redo plan (Chunk 5): capture deleted elements + their
    // HTML bodies BEFORE the deletion so undo restores them.
    const deletedElements = Array.from(selectedIds.value)
      .map((id) => {
        const el = elements.value.find((e) => e.id === id)
        if (!el) return null
        return { element: { ...el }, htmlBody: null as string | null }
      })
      .filter((e): e is { element: DesignElementApi; htmlBody: string | null } => e !== null)
    void history.captureDelete(deletedElements)
    for (const id of Array.from(selectedIds.value)) {
      void workspacesStore.deleteDesignElement(
        props.workspaceId,
        effectiveItemId.value,
        activePageId.value,
        id,
      )
    }
    selectedIds.value = new Set()
    return
  }

  // Cmd/Ctrl+P toggles Preview/Edit mode. Plain P (no modifier) is a common type-to-pan shortcut in
  // design tools — not used here, but we intentionally don't bind it so the future pan-tool doesn't
  // conflict.
  if (
    (event.key === 'p' || event.key === 'P') &&
    (event.ctrlKey || event.metaKey) &&
    !event.shiftKey &&
    !event.altKey
  ) {
    event.preventDefault()
    togglePreviewMode()
    return
  }

  // NEW (Chunk 6 of grouped-layers plan): Cmd/Ctrl+G groups the current selection into a new
  // `group` at the union bbox. Figma convention. The composable enforces the 2+ selection rule
  // silently (mirrors Figma's Cmd+G).
  if (
    (event.key === 'g' || event.key === 'G') &&
    (event.ctrlKey || event.metaKey) &&
    !event.altKey
  ) {
    event.preventDefault()
    if (event.shiftKey) {
      if (selectedIds.value.size === 1) {
        const onlyId = Array.from(selectedIds.value)[0]
        if (onlyId) void designHandlers.ungroupSelection(onlyId)
      }
      return
    }
    // Undo/redo plan (Chunk 5): capture the group entry before
    // the selection gets cleared by the composable.
    void history.captureGroup('__pending__', Array.from(selectedIds.value), true)
    void designHandlers.groupSelection()
    return
  }

  // Undo/redo keyboard shortcuts (Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z, Cmd/Ctrl+Y) were intentionally
  // removed in 2026-08-06 when the feature was hidden from the design UI. Browser-native Cmd+Z now
  // reaches the user unimpeded.
  if (
    (event.key === 'f' || event.key === 'F' || (event.key === '1' && event.shiftKey)) &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey
  ) {
    event.preventDefault()
    zoomFit()
  }

  // Arrow keys nudge the selection by 1 design-px; Shift+arrow by 10.
  // Gated on `selectedIds.size > 0` (Figma-style: arrows do nothing
  // when there's nothing to nudge).
  if (
    selectedIds.value.size > 0 &&
    (event.key === 'ArrowLeft' ||
      event.key === 'ArrowRight' ||
      event.key === 'ArrowUp' ||
      event.key === 'ArrowDown')
  ) {
    event.preventDefault()
    const step = event.shiftKey ? 10 : 1
    const dx = event.key === 'ArrowLeft' ? -step : event.key === 'ArrowRight' ? step : 0
    const dy = event.key === 'ArrowUp' ? -step : event.key === 'ArrowDown' ? step : 0
    // Undo/redo plan (Chunk 4): each keypress is one undo entry (Figma parity). Pre-state is
    // captured BEFORE the PATCH loop; post-state AFTER. capturePostState is async (reads HTML
    // body); we don't await so the next keypress queues the next capture.
    void history.capturePreState(Array.from(selectedIds.value))
    for (const id of selectedIds.value) {
      const el = elements.value.find((e) => e.id === id)
      if (!el) continue
      // The element's "effective" position is the cached `el.x` plus the accumulated nudge delta
      // (since the last time `elements.value` was fresh). Without this, the second arrow press
      // would read the stale `el.x` and re-emit the same x, freezing the element.
      const off = nudgeOffsets.get(id) ?? { x: 0, y: 0 }
      const baseX = el.x + off.x
      const baseY = el.y + off.y
      const newX = baseX + dx
      const newY = baseY + dy
      nudgeOffsets.set(id, { x: newX - el.x, y: newY - el.y })
      void workspacesStore.updateDesignElementGeometry(
        props.workspaceId,
        effectiveItemId.value,
        activePageId.value,
        id,
        { x: newX, y: newY },
      )
    }
    void history.capturePostState(Array.from(selectedIds.value))
    return
  }
}

const handleKeyup = (event: KeyboardEvent): void => {
  // Release Space. Don't gate on target — if focus moved to an input
  // mid-press, we still want to clear the body cursor on Space-up.
  if (event.key === ' ' && isSpacePressed.value) {
    isSpacePressed.value = false
    document.body.style.cursor = ''
  }
}

const handleWindowBlur = (): void => {
  // Defensive: if focus is lost (window blur / tab switch) while
  // Space is held, the keyup event may never fire. Reset so we
  // don't leave the cursor stuck on "grab".
  if (isSpacePressed.value) {
    isSpacePressed.value = false
    document.body.style.cursor = ''
  }
}

onMounted(() => {
  document.addEventListener('keydown', handleKeydown)
  document.addEventListener('keyup', handleKeyup)
  window.addEventListener('blur', handleWindowBlur)
})
onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
  document.removeEventListener('keyup', handleKeyup)
  window.removeEventListener('blur', handleWindowBlur)
  // Defensive: clear body cursor if we unmount mid-press.
  document.body.style.cursor = ''
  // Clear pinch-zoom state — if pointers are still active (rare,
  // but possible across the chat-toggle unmount/mount cycle), the
  // next mount would otherwise see stale entries.
  pinchPointers.clear()
  pinchStartDistance = null
  pinchStartZoom = null
  // NOTE: we intentionally do NOT clear `activeDesignPageId` here. Why: AppLayout's main-content
  // v-else-if chain renders TWO <DesignView> instances for the same design item — one in the
  // single-column branch (no chat open) and one inside the 3-column branch (chat open).
})

// ─── Handlers ──────────────────────────────────────────────────────────
const handleCanvasClick = (event: MouseEvent): void => {
  // In Preview mode, canvas clicks are user-typed values inside iframes or pan gestures — neither
  // should clear the selection.
  if (isPreviewMode.value) return
  // If we just finished a pan-drag (Space + drag), swallow the click so it doesn't deselect the
  // active element. The browser dispatches a synthetic click after pointerup; without this guard,
  // every pan ends with selection-clear.
  if (isPanning.value) return
  // Only clear selection when clicking the canvas itself (not an element child). The DesignElement
  // child events fire before this and they stopPropagation on their pointerdown — so this handler
  // is only called for the canvas background.
  if ((event.target as HTMLElement | null)?.closest('[data-design-element]')) {
    return
  }
  selectedIds.value = new Set()
}

// Chunk 3 (right-click group menu plan): per-instance context menu
// for canvas right-clicks. Preview mode silently ignores right-clicks
// (Figma parity: the menu is editor-only).
const canvasContextMenu = useDesignContextMenu()
function handleCanvasContextMenu(event: MouseEvent): void {
  if (isPreviewMode.value) return
  // Open with the current selection — right-click on empty canvas acts on whatever was previously
  // selected. The LayersPanel owns its own context-menu instance for row-level right-clicks; this
  // one is canvas-only.
  canvasContextMenu.open(event, Array.from(selectedIds.value))
}

// True while the user is mid-drag with Space held. Gates the
// canvas-click deselection guard above.
const isPanning = ref(false)

// Pointer-drag pan. Fires on the canvas scroll container; only does anything when Space is held.
const startCanvasPan = (event: PointerEvent): void => {
  if (!isSpacePressed.value) return
  // Primary button only — middle / right clicks do different things
  // (autoscroll, context menu) on some browsers.
  if (event.button !== 0) return
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  isPanning.value = true
  document.body.style.cursor = 'grabbing'

  // Snapshot the scroll position + pointer position at drag start.
  // The move handler subtracts the cursor delta from the original
  // scroll position so the canvas appears to follow the cursor.
  const startScrollLeft = target.scrollLeft
  const startScrollTop = target.scrollTop
  const startClientX = event.clientX
  const startClientY = event.clientY

  const onMove = (e: PointerEvent): void => {
    // cursor delta in screen-px = scroll delta in scroll-px
    // (no zoom division needed — scrollLeft / scrollTop are in
    // unscaled coords; the inner div's scale() does not affect them).
    const dx = e.clientX - startClientX
    const dy = e.clientY - startClientY
    target.scrollLeft = startScrollLeft - dx
    target.scrollTop = startScrollTop - dy
  }
  const onUp = (e: PointerEvent): void => {
    if (target.hasPointerCapture(e.pointerId)) {
      target.releasePointerCapture(e.pointerId)
    }
    isPanning.value = false
    // Restore grab cursor only if Space is still held; otherwise
    // clear back to the default cursor.
    document.body.style.cursor = isSpacePressed.value ? 'grab' : ''
    target.removeEventListener('pointermove', onMove)
    target.removeEventListener('pointerup', onUp)
    target.removeEventListener('pointercancel', onUp)
  }
  target.addEventListener('pointermove', onMove)
  target.addEventListener('pointerup', onUp)
  target.addEventListener('pointercancel', onUp)
}

// NEW: chat-toggle click handler (top-right 💬 button in the canvas header bar).
const handleOpenChat = (): void => {
  const page = activePage.value
  emit('openChat', {
    pageId: page?.id ?? '',
    pageName: page?.name ?? '',
    workspaceItemTaskId: page?.workspace_item_task_id ?? '',
  })
}

// Compute the next available placeholder name for a new design page. Mirrors the macOS / Figma
// convention: the very first untitled page is `"Untitled"` (no suffix), every subsequent one is
// `"Untitled N"` where `N` is `max(existing numbers) + 1`.
const UNTITLEDBASE_NAME = 'Untitled'
const UNTITLEDPATTERN = /^Untitled (\d+)$/
const computeNextUntitledName = (existingPages: ReadonlyArray<{ name: string }>): string => {
  let hasUnnumbered = false
  let maxNumbered = 0
  for (const p of existingPages) {
    if (p.name === UNTITLEDBASE_NAME) {
      hasUnnumbered = true
      continue
    }
    const match = UNTITLEDPATTERN.exec(p.name)
    if (match && match[1]) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > 0 && n > maxNumbered) {
        maxNumbered = n
      }
    }
  }
  // Very first page: no unnumbered, no numbered → "Untitled". Everything else: take maxNumbered +
  // 1. If only an unnumbered "Untitled" exists (maxNumbered === 0), return "Untitled 1" because we
  // can't collide with the existing literal.
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLEDBASE_NAME
  return `${UNTITLEDBASE_NAME} ${maxNumbered + 1}`
}

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
// setup>` auto-surfaces top-level bindings but eslint can't see the `vm.X` reflection path, so the
// rule fires.
const handleSelectPage = (pageId: string): void => {
  // Mirror to the store first so AppLayout's design handlers (handleDesignUpdateElement /
  // handleDesignDeleteElement) always see the latest selection, even if the page-change
  // early-returns below.
  choosePage(pageId)
  // Re-emit for any external listener (AppLayout's @select-page
  // does nothing today, but the contract is preserved).
  emit('selectPage', pageId)
}

// Delete a design page. NEW (design-pages-in-workspace-tree plan, 2026-08-06): routes through the
// store so the cache + `activeDesignPageId` fallback happen in one place.
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

// Figma-style multi-select toggle. Plain click (additive=false) replaces the selection with just
// this element. Shift+click (additive=true) adds or removes membership without disturbing the rest
// of the selection.
const handleElementToggle = (elementId: string, additive: boolean): void => {
  if (additive) {
    const next = new Set(selectedIds.value)
    if (next.has(elementId)) next.delete(elementId)
    else next.add(elementId)
    selectedIds.value = next
  } else {
    selectedIds.value = new Set([elementId])
  }
  emit('selectElement', elementId)
}

// Keep the legacy handler name around as an alias so LayersPanel's `@select="_handleElementSelect"`
// (which emits a plain elementId with no additive flag) still works — LayersPanel gets the additive
// flag from the Shift state on the row click and emits a structured
// payload instead.
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _handleElementSelect = (elementId: string): void => {
  handleElementToggle(elementId, false)
}

const handleElementUpdate = (patch: Partial<DesignElementApi>): void => {
  if (selectedIds.value.size === 0) return
  // When multiple elements are selected, apply the patch to every one
  // of them (Figma semantics — editing the X/Y in the PropertiesPanel
  // moves the whole selection together).
  if (selectedIds.value.size === 1) {
    const id = selectedIds.value.values().next().value as string
    emit('updateElement', id, patch)
    return
  }
  for (const id of selectedIds.value) {
    emit('updateElement', id, patch)
  }
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the `translate` event fired by
 * DesignElement during a single-element drag (move mode). The payload is the cursor DELTA in
 * design-px PLUS the source element id. */
/** Routes through `useDesignHandlers.translateElement` → POST /translate. The backend handles
 * cascade-to-descendants for groups, so we just forward the delta + the element id. */
/** BUG FIX (2026-08-06): previously bailed with `selectedIds.size !== 1` — relying on the parent's
 * selectedIds state. */
/** That was fragile: if the user shift-clicked to deselect (toggle removed the dragged id) or if a
 * stale multi-select from earlier wasn't cleared, the single-element drag would silently no-op. */
/** Now we trust the elementId from the event payload and only fall back to `selectedIds` for
 * back-compat. */
const handleElementTranslate = (payload: { elementId?: string; dx: number; dy: number }): void => {
  // Prefer the elementId from the event (the drag SOURCE knows what it is).
  // Fall back to selectedIds only if the event doesn't carry it (older
  // callers that emit `{ dx, dy }` without elementId).
  let id: string | undefined = payload.elementId
  if (!id && selectedIds.value.size === 1) {
    id = selectedIds.value.values().next().value as string
  }
  if (!id) {
    designLogger.warn({
      reason: 'handle:translateElement',
      caller: 'DesignView.handleElementTranslate',
      dx: payload.dx,
      dy: payload.dy,
      extra: {
        selectedIdsSize: selectedIds.value.size,
        selectedIdsContents: Array.from(selectedIds.value),
        reason: 'no elementId in event and selectedIds is not exactly 1',
      },
    })
    return
  }
  designLogger.info({
    reason: 'handle:translateElement',
    caller: 'DesignView.handleElementTranslate',
    dx: payload.dx,
    dy: payload.dy,
    extra: { id },
  })
  emit('translateElement', id, payload.dx, payload.dy)
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the `resize` event fired by DesignElement
 * during a resize gesture. The payload is the absolute target geometry after applying the cursor
 * delta. Routes through `useDesignHandlers.resizeElement` → POST /resize. */
/** Resize never cascades (Figma convention). */
const handleElementResize = (patch: Partial<DesignElementApi>): void => {
  if (selectedIds.value.size !== 1) {
    designLogger.warn({
      reason: 'handle:resizeElement',
      caller: 'DesignView.handleElementResize',
      patch,
      extra: { selectedIdsSize: selectedIds.value.size, reason: 'no single selection' },
    })
    return
  }
  const id = selectedIds.value.values().next().value as string
  designLogger.info({
    reason: 'handle:resizeElement',
    caller: 'DesignView.handleElementResize',
    patch,
    extra: { id },
  })
  emit('resizeElement', id, patch)
}

const handleElementHtmlChanged = (html: string): void => {
  if (selectedIds.value.size !== 1) return
  // HTML body editing only applies to a single selected element —
  // there's no sensible "merge HTML across 3 elements" semantic.
  const id = selectedIds.value.values().next().value as string
  emit('htmlChanged', id, html)
}

const handleElementDelete = (elementId: string): void => {
  emit('deleteElement', elementId)
  // Remove the deleted id from the selection Set (don't clear the
  // whole selection — if the user multi-selected and deleted one,
  // the others should remain selected for further action).
  if (selectedIds.value.has(elementId)) {
    const next = new Set(selectedIds.value)
    next.delete(elementId)
    selectedIds.value = next
  }
}

const handleReorderElements = (orderedElementIds: string[]): void => {
  emit('reorderElements', orderedElementIds)
}

// LayersPanel emits a structured payload so Shift+click can be
// distinguished from a plain click. Both call into handleElementToggle.
const handleLayerSelect = (payload: { elementId: string; additive: boolean }): void => {
  handleElementToggle(payload.elementId, payload.additive)
}

// NEW (Chunk 4 Task 4.3 of drag-to-reparent plan): the LayersPanel emits `reparent` after a
// successful drag-and-drop.
const handleLayerReparent = (payload: {
  elementIds: string[]
  newParentId: string | null
}): void => {
  void designHandlers.reparentLayers({
    workspaceId: props.workspaceId,
    itemId: effectiveItemId.value,
    pageId: activePageId.value,
    elementIds: payload.elementIds,
    newParentId: payload.newParentId,
  })
}

// NEW (Chunk 2 of the right-click group menu plan): when the layers panel emits `group` from the
// context menu, mirror the Cmd+G path: inject the targetIds into the local `selectedIds` ref so
// `useDesignHandlers.groupSelection()` (which reads from `selectedIds.value`) acts on them.
const handleDesignGroupFromContextMenu = (targetIds: string[]): void => {
  if (targetIds.length < 2) return
  selectedIds.value = new Set(targetIds)
  // Push the group entry — the parent group's id is determined by the backend; for the capture
  // entry we record `beforeParentExisted: true` (parent row doesn't exist yet) and use a
  // placeholder id that the composable's inverse will treat as "no-op".
  void history.captureGroup('__pending__', targetIds, true)
  void designHandlers.groupSelection()
}

// Expand a selection to include the transitive children of any group / frame in the selection. When
// a user selects just the group (not its children), this lets them drag the group AND every
// descendant in one motion — matching Figma's behaviour.
function _expandSelectionWithDescendants(
  ids: ReadonlySet<string>,
  all: ReadonlyArray<DesignElementApi>,
): Set<string> {
  const out = new Set<string>(ids)
  // Iterate to a fixed point so deeply-nested groups (group inside
  // group inside group) all expand.
  let changed = true
  while (changed) {
    changed = false
    for (const e of all) {
      if (out.has(e.id) && e.parent_id && out.has(e.parent_id)) {
        // Already reachable via an expanded ancestor.
        continue
      }
      if (e.parent_id && out.has(e.parent_id) && !out.has(e.id)) {
        out.add(e.id)
        changed = true
      }
    }
  }
  return out
}

// Chunk 9 of grouped-layers plan: dissolve the single selected group/frame. Mirrors
// handleDesignGroupFromContextMenu but takes a single id (groups always dissolve one at a time).
// Cmd+Shift+G and the right-click menu both route here.
const handleDesignUngroupFromContextMenu = (elementId: string): void => {
  if (!elementId) return
  void designHandlers.ungroupSelection(elementId)
}

// NEW (2026-08-06, design-leave-group plan): pull the SINGLE selected element out of its current
// parent group/frame to top-level. Distinct from Ungroup (which dissolves the selected group
// itself) — the parent group survives and any other children stay nested.
const handleDesignLeaveGroupFromContextMenu = (elementId: string): void => {
  if (!elementId) return
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  void designHandlers.leaveGroup(elementId)
}

// NEW (2026-08-06, design-move-to-page plan, Chunk 8): open the MoveToPageDialog with the
// right-clicked element. The dialog itself drives the API call — we just open it with the right
// element id and source page.
const moveToPageDialogElementId = ref<string>('')
const moveToPageDialogVisible = computed({
  get: () => moveToPageDialogElementId.value !== '',
  set: (v) => {
    if (!v) moveToPageDialogElementId.value = ''
  },
})
const handleDesignMoveToPageFromContextMenu = (elementId: string): void => {
  if (!elementId) return
  if (!props.workspaceId || !effectiveItemId.value || !activePageId.value) return
  moveToPageDialogElementId.value = elementId
}
const handleDesignMoveToPageDialogSelect = async (newPageId: string): Promise<void> => {
  const elementId = moveToPageDialogElementId.value
  if (!elementId || !props.workspaceId || !effectiveItemId.value || !activePageId.value) {
    moveToPageDialogElementId.value = ''
    return
  }
  const success = await designHandlers.moveToPage(elementId, newPageId)
  // Close the dialog regardless — failure already shows an error toast.
  moveToPageDialogElementId.value = ''
  // Q6: handler navigates to the target page on success (no-op on failure).
  void success
}
const handleDesignMoveToPageDialogClose = (): void => {
  moveToPageDialogElementId.value = ''
}

// Chunk 2: group drag. BUG FIX (2026-07-29): the original implementation used `el.x + finalDx`
// where `el.x` is the element's CURRENT position from `elements.value`.
let dragStartPositions: Map<string, { x: number; y: number }> | null = null

const handleGroupDrag = (delta: { dx: number; dy: number }): void => {
  console.log('[handleGroupDrag] called', { delta, selectedCount: selectedIds.value.size })
  if (selectedIds.value.size === 0) return
  if (!props.workspaceId || !effectiveItemId.value) return
  if (!activePageId.value) return
  const pageId = activePageId.value
  const itemId = effectiveItemId.value
  const workspaceId = props.workspaceId

  // ─── Snap (Chunk 3) ───────────────────────────────────────────────
  const selected = elements.value.filter((e) => selectedIds.value.has(e.id))
  console.log(
    '[handleGroupDrag] selected elements',
    selected.map((e) => e.id),
  )
  if (selected.length > 0) {
    if (dragStartPositions === null) {
      dragStartPositions = new Map()
      for (const el of selected) {
        dragStartPositions.set(el.id, { x: el.x, y: el.y })
      }
      console.log('[handleGroupDrag] snapshot created (fresh)', {
        size: dragStartPositions.size,
        ids: Array.from(dragStartPositions.keys()),
      })
      designLogger.info({
        reason: 'handle:dragStart:resetSnapshot',
        caller: 'DesignView.handleGroupDrag',
        snapshotFresh: true,
        snapshotSize: dragStartPositions.size,
        extra: { ids: Array.from(dragStartPositions.keys()) },
      })
    } else {
      console.warn('[handleGroupDrag] STALE SNAPSHOT detected', {
        size: dragStartPositions.size,
        ids: Array.from(dragStartPositions.keys()),
      })
      designLogger.warn({
        reason: 'handle:dragStart:resetSnapshot',
        caller: 'DesignView.handleGroupDrag',
        snapshotFresh: false,
        snapshotSize: dragStartPositions.size,
        extra: {
          ids: Array.from(dragStartPositions.keys()),
          note: 'dragStartPositions was NOT null on entry — likely a leaked snapshot from the previous drag',
        },
      })
    }
    const originalPos = (e: DesignElementApi): { x: number; y: number } =>
      dragStartPositions!.get(e.id) ?? { x: e.x, y: e.y }

    const minX = Math.min(...selected.map((e) => originalPos(e).x + delta.dx))
    const minY = Math.min(...selected.map((e) => originalPos(e).y + delta.dy))
    const maxX = Math.max(...selected.map((e) => originalPos(e).x + delta.dx + e.width))
    const maxY = Math.max(...selected.map((e) => originalPos(e).y + delta.dy + e.height))
    const unionBbox = {
      id: '__union__',
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY,
    }
    console.log('[handleGroupDrag] unionBbox', unionBbox)

    const others = elements.value.filter((e) => !selectedIds.value.has(e.id))
    console.log('[handleGroupDrag] snap targets (others) count', others.length)

    const snapResult = computeSnapDelta([unionBbox, ...others], '__union__', 0, 0)
    console.log('[handleGroupDrag] snapResult', snapResult)

    snapGuides.value = snapResult.guides
    const finalDx = delta.dx + snapResult.dx
    const finalDy = delta.dy + snapResult.dy
    console.log('[handleGroupDrag] finalDx/finalDy', {
      finalDx,
      finalDy,
      rounded: { dx: Math.round(finalDx), dy: Math.round(finalDy) },
    })

    void designHandlers.moveElementWithDescendants({
      workspaceId,
      itemId,
      pageId,
      items: selected.map((el) => ({
        element_id: el.id,
        dx: Math.round(finalDx),
        dy: Math.round(finalDy),
      })),
    })
    console.log('[handleGroupDrag] moveElementWithDescendants dispatched', {
      workspaceId,
      itemId,
      pageId,
      count: selected.length,
    })

    designLogger.info({
      reason: 'handle:groupDrag',
      caller: 'DesignView.handleGroupDrag',
      ids: selected.map((el) => el.id),
      dx: Math.round(finalDx),
      dy: Math.round(finalDy),
      workspaceId,
      itemId,
      pageId,
    })
    return
  }
}

// Undo/redo plan (Chunk 4): gesture boundary capture. The pre-state is captured at drag-start
// (pointerdown); the post- state at drag-end (pointerup trailing emit). REGRESSION (2026-07-30):
// this handler REPLACED the original `clearSnapGuides` on the `@drag-end` binding.
const handleDragStart = (ids: string[]): void => {
  void history.capturePreState(ids)
}
const handleDragEnd = (): void => {
  designLogger.info({
    reason: 'handle:dragEnd:snapshot=null',
    caller: 'DesignView.handleDragEnd',
    extra: { previousSnapshotSize: 'reset to null' },
  })
  dragStartPositions = null
  void history
    .capturePostState(
      // For single-element drag, ids is implicit (just this element). For multi-element drag, ids
      // has been captured. We pass an empty array as a safety net — capturePostState re-reads the
      // live state from the store and diffs against the pre-state we captured above.
      Array.from(selectedIds.value),
    )
    .then(() => {
      snapGuides.value = []
    })
}

const handleCreateElement = (body: {
  name: string
  type: DesignElementApi['type']
  html: string
}): void => {
  emit('createElement', body)
}

const handlePropertiesDelete = (elementId: string): void => {
  handleElementDelete(elementId)
}

const handlePropertiesUpdate = (patch: Partial<DesignElementApi>): void => {
  handleElementUpdate(patch)
}

const handlePropertiesHtmlChanged = (html: string): void => {
  handleElementHtmlChanged(html)
}

// ─── Zoom (transform: scale on the canvas wrapper) ──────────────────── Pure-view state; doesn't
// change page dimensions or element positions. Persists per design item in localStorage so a user
// who zooms to 75% on one design item doesn't affect another item.
const ZOOM_KEY_PREFIX = 'design-view-zoom-'
const ZOOM_DEFAULT = 1.0
const ZOOM_MIN = 0.1
const ZOOM_MAX = 4.0
const ZOOM_STEP = 0.1 // each toolbar button click
const ZOOM_WHEEL_STEP = 0.05 // each Ctrl+wheel notch (Shift = ×4)

const loadZoom = (itemId: string): number => {
  try {
    const raw = localStorage.getItem(ZOOM_KEY_PREFIX + itemId)
    if (!raw) return ZOOM_DEFAULT
    const n = Number(raw)
    if (!Number.isFinite(n)) return ZOOM_DEFAULT
    return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, n))
  } catch {
    return ZOOM_DEFAULT
  }
}
const saveZoom = (itemId: string, n: number): void => {
  try {
    localStorage.setItem(ZOOM_KEY_PREFIX + itemId, String(n))
  } catch {
    /* no-op — localStorage may be disabled */
  }
}

const zoom = ref<number>(ZOOM_DEFAULT)
const setZoom = (next: number): void => {
  const clamped = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, next))
  // Snap to nearest 1% so the displayed percentage is clean.
  const snapped = Math.round(clamped * 100) / 100
  zoom.value = snapped
  if (effectiveItemId.value) saveZoom(effectiveItemId.value, snapped)
}
const zoomIn = (): void => setZoom(zoom.value + ZOOM_STEP)
const zoomOut = (): void => setZoom(zoom.value - ZOOM_STEP)
const zoomReset = (): void => setZoom(1.0)

// Fit-to-viewport: compute the zoom level that makes the union bbox of all elements fit inside the
// scroll container with a small margin, then scroll the container so the elements appear centered.
// Mirrors Figma's Shift+1 ("Zoom to fit").
const ZOOM_FIT_MARGIN = 48 // px of padding around the fitted canvas
const ZOOM_FIT_DEFAULT_W = 1440
const ZOOM_FIT_DEFAULT_H = 1024

const zoomFit = (): void => {
  if (!activePage.value) return
  const container = document.querySelector<HTMLElement>(
    '[data-testid="design-canvas-scroll-container"]',
  )
  if (!container) return
  const cw = container.clientWidth - ZOOM_FIT_MARGIN
  const ch = container.clientHeight - ZOOM_FIT_MARGIN
  if (cw <= 0 || ch <= 0) return

  // Union bbox of elements (or default if none).
  let minX = 0
  let minY = 0
  let contentW = ZOOM_FIT_DEFAULT_W
  let contentH = ZOOM_FIT_DEFAULT_H
  if (elements.value.length > 0) {
    minX = Math.min(...elements.value.map((e) => e.x))
    minY = Math.min(...elements.value.map((e) => e.y))
    const maxX = Math.max(...elements.value.map((e) => e.x + e.width))
    const maxY = Math.max(...elements.value.map((e) => e.y + e.height))
    contentW = maxX - minX
    contentH = maxY - minY
  }

  const zoomX = cw / contentW
  const zoomY = ch / contentH
  const fit = Math.min(zoomX, zoomY)
  setZoom(fit)
  // Center after the scale change so the elements appear centered. The scroll math mirrors the
  // Ctrl+wheel handler, but offset by the elements' minX/minY (the canvas div is auto-grown to wrap
  // elements, so the scroll origin is the bbox top-left, not 0,0).
  requestAnimationFrame(() => {
    const scaledW = contentW * zoom.value
    const scaledH = contentH * zoom.value
    container.scrollLeft = minX * zoom.value + (scaledW - container.clientWidth) / 2
    container.scrollTop = minY * zoom.value + (scaledH - container.clientHeight) / 2
  })
}

// Pinch-to-zoom via Pointer Events (trackpad / touchscreen / Linux WebKitGTK).
interface PinchPointer {
  startX: number
  startY: number
  currentX: number
  currentY: number
}

const pinchPointers = new Map<number, PinchPointer>()
let pinchStartDistance: number | null = null
let pinchStartZoom: number | null = null

const onPinchPointerDown = (event: PointerEvent): void => {
  // Run the Space-pan handler first — it's a no-op when Space isn't held, and we want both gestures
  // to coexist on the same element (chained instead of multiple @pointerdown listeners because Vue
  // 3 templates only bind one listener per event per element).
  startCanvasPan(event)
  // Mouse can't pinch (single-pointer by definition). Pen / touch only.
  if (event.pointerType === 'mouse') return
  // Don't pinch-zoom when pinching on a design element — let the
  // element's own pointerdown handler take the gesture for drag.
  const targetEl = event.target as HTMLElement | null
  if (targetEl?.closest('[data-design-element]')) return
  const target = event.currentTarget as HTMLElement | null
  if (!target) return
  target.setPointerCapture(event.pointerId)
  pinchPointers.set(event.pointerId, {
    startX: event.clientX,
    startY: event.clientY,
    currentX: event.clientX,
    currentY: event.clientY,
  })
  if (pinchPointers.size === 2) {
    const [p1, p2] = [...pinchPointers.values()] as [PinchPointer, PinchPointer]
    pinchStartDistance = Math.hypot(p2.startX - p1.startX, p2.startY - p1.startY)
    pinchStartZoom = zoom.value
  }
}

const onPinchPointerMove = (event: PointerEvent): void => {
  const p = pinchPointers.get(event.pointerId)
  if (!p) return
  p.currentX = event.clientX
  p.currentY = event.clientY
  if (pinchPointers.size < 2 || pinchStartDistance == null || pinchStartZoom == null) return
  // Two fingers starting at the same point gives distance=0; division
  // would explode. Treat as no-op until the user actually moves a finger.
  if (pinchStartDistance <= 0) return
  const [p1, p2] = [...pinchPointers.values()] as [PinchPointer, PinchPointer]
  const currentDistance = Math.hypot(p2.currentX - p1.currentX, p2.currentY - p1.currentY)
  const ratio = currentDistance / pinchStartDistance
  const newZoom = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, pinchStartZoom * ratio))
  setZoom(newZoom)
}

const onPinchPointerEnd = (event: PointerEvent): void => {
  pinchPointers.delete(event.pointerId)
  const target = event.currentTarget as HTMLElement | null
  if (target && target.hasPointerCapture(event.pointerId)) {
    target.releasePointerCapture(event.pointerId)
  }
  if (pinchPointers.size < 2) {
    pinchStartDistance = null
    pinchStartZoom = null
  }
}

// Ctrl+wheel zooms in/out at the cursor position. The plain wheel
// is left alone (it scrolls the canvas container as usual — matches
// Figma / Miro / VS Code). Shift wheel zooms ×4 faster.
const handleCanvasWheel = (event: WheelEvent): void => {
  if (!event.ctrlKey && !event.metaKey) return
  event.preventDefault()
  const direction = event.deltaY < 0 ? 1 : -1
  const speed = event.shiftKey ? 4 : 1
  const next = zoom.value + direction * ZOOM_WHEEL_STEP * speed

  // Anchor the zoom at the cursor position so zoom-in feels natural (the point under the cursor
  // stays under the cursor after the scale).
  const container = event.currentTarget as HTMLElement | null
  if (!container) {
    setZoom(next)
    return
  }
  const rect = container.getBoundingClientRect()
  const cursorX = event.clientX - rect.left + container.scrollLeft
  const cursorY = event.clientY - rect.top + container.scrollTop
  const before = zoom.value
  setZoom(next)
  const after = zoom.value
  if (before === after) return
  const ratio = after / before
  container.scrollLeft = cursorX * ratio - (event.clientX - rect.left)
  container.scrollTop = cursorY * ratio - (event.clientY - rect.top)
}

// Restore zoom on design-item change (different localStorage key). Mount covers the initial item
// (the parent keys this component by item id, so item switches remount); the prev-id guard covers
// itemId prop changes on a reused instance.
const prevZoomItemId = ref(effectiveItemId.value)
onMounted(() => {
  prevZoomItemId.value = effectiveItemId.value
  zoom.value = effectiveItemId.value ? loadZoom(effectiveItemId.value) : ZOOM_DEFAULT
})
onUpdated(() => {
  if (effectiveItemId.value !== prevZoomItemId.value) {
    prevZoomItemId.value = effectiveItemId.value
    zoom.value = effectiveItemId.value ? loadZoom(effectiveItemId.value) : ZOOM_DEFAULT
  }
})

// ─── Page-size inputs were removed ────────────────────────────────────── The W × H header inputs
// have been removed (plan docs/superpowers/plans/2026-07-29-remove-canvas-background.md): pages no
// longer have a visible rectangle / enforced boundary.
</script>

<template>
  <section
    class="design-view flex flex-col h-full min-h-0"
    :data-design-item-id="item.id"
    data-testid="design-view"
  >
    <!--
      NEW (2026-07-14): Top-level action bar. Always renders
      regardless of pages state (loading / error / empty / canvas)
      so the chat toggle is reachable even before the user has
      added a page — the primary flow is "ask the LLM to draw me
      a login form" via the chat, then the page appears. Without
      this top-level bar, the chat toggle was buried inside the
      canvas header which only renders when pages.length > 0, so
      the empty state had no chat access (the bug the user
      reported on 2026-07-14).

      Layout: [item name | flex spacer | 💬 Chat button]. The
      item name is small + dim so it doesn't compete with the
      page tabs for attention; the chat button is the only
      always-visible action.
    -->
    <div
      class="px-3 py-2 flex items-center gap-3 shrink-0"
      style="
        border-bottom: 1px solid var(--color-border);
        background-color: var(--semantic-sidebar-bg);
      "
      data-testid="design-toolbar"
    >
      <div
        class="text-dense font-medium truncate"
        style="color: var(--semantic-text-dim)"
        :title="item.name"
      >
        {{ item.name }}
      </div>
      <div class="flex-1" />
      <button
        type="button"
        class="px-2.5 py-1 rounded text-dense font-medium flex items-center gap-1.5 transition-opacity duration-150 hover:opacity-100"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        data-testid="design-open-chat-button"
        aria-label="Open design chat"
        title="Open design chat"
        @click="handleOpenChat"
      >
        <UiIcon name="chat" />
        <span>Chat</span>
      </button>
    </div>

    <!--
      (2026-08-06): the <DesignPageTabs> row at the top of DesignView
      is removed. Pages now live in the workspace sidebar tree
      (WorkspaceItem.vue renders DesignPageRow under expanded design
      items). The canvas header still shows the active page name so
      the user knows which page they're on. The empty state below
      ("+ Add the first page") is preserved for users who navigate
      into DesignView before expanding the tree (e.g. via deep link).
    -->

    <!-- ─── Loading state for pages ───────────────────────────────── -->
    <div
      v-if="pagesLoading"
      class="flex-1 flex items-center justify-center text-body"
      style="color: var(--semantic-text-dim)"
      data-testid="design-pages-loading"
    >
      Loading pages…
    </div>

    <!-- ─── Error state for pages ─────────────────────────────────── -->
    <div
      v-else-if="pagesError"
      class="flex-1 flex items-center justify-center text-body"
      style="color: rgb(248, 113, 113)"
      data-testid="design-pages-error"
    >
      Failed to load pages: {{ pagesError }}
    </div>

    <!-- ─── Empty state (no pages) ────────────────────────────────── -->
    <div
      v-else-if="pages.length === 0"
      class="flex-1 flex items-center justify-center"
      data-testid="design-pages-empty"
    >
      <div class="text-center">
        <div class="text-display mb-2" style="color: var(--semantic-text-dim)" aria-hidden="true">
          ▤
        </div>
        <div class="text-body mb-4" style="color: var(--semantic-text-dim)">No pages yet</div>
        <button
          type="button"
          class="px-3 py-1.5 rounded-lg text-body font-medium"
          style="
            background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
            color: var(--color-bg);
          "
          @click="handleAddPage"
        >
          + Add the first page
        </button>
      </div>
    </div>

    <!-- ─── Main split (canvas + right sidebar) ──────────────────── -->
    <div v-else class="flex-1 flex min-h-0">
      <!-- Canvas column -->
      <div class="flex-1 flex flex-col min-w-0 min-h-0" data-testid="design-canvas-column">
        <!-- Canvas header bar -->
        <div
          class="px-3 py-2 flex items-center gap-3 shrink-0"
          style="
            border-bottom: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
          "
          data-testid="design-canvas-header"
        >
          <button
            v-if="!isPreviewMode"
            type="button"
            class="px-2 py-1 rounded text-dense font-medium"
            style="
              background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
              color: var(--color-bg);
            "
            data-testid="design-add-element-button"
            @click="openAddElementDialog"
          >
            + Element
          </button>
          <!--
            Undo/Redo toolbar was intentionally removed (2026-08-06):
            the feature is HIDDEN from the user in design mode.
            Internal plumbing (useDesignHistory composable +
            history.capture*() calls) is retained for clean future
            re-enable — see DesignView.undoHidden.spec.ts.
          -->
          <div
            v-if="activePage"
            class="text-dense flex-1 truncate"
            style="color: var(--semantic-text)"
            :title="activePage.name"
          >
            {{ activePage.name }}
          </div>
          <div v-else class="text-dense flex-1" style="color: var(--semantic-text-dim)">
            (no page selected)
          </div>
          <div class="text-dense" style="color: var(--semantic-text-dim)">
            {{ elements.length }} element{{ elements.length === 1 ? '' : 's' }}
          </div>
          <!--
            Preview/Edit mode toggle. When active, each element's iframe
            gets `pointer-events: auto` and the edit chrome is suppressed
            — the user can type into form fields and click buttons inside
            the rendered HTML without selecting elements. Keyboard shortcut:
            Cmd/Ctrl+P toggles, Esc exits. See `isPreviewMode` ref above.
          -->
          <button
            type="button"
            class="px-2 py-0.5 rounded text-dense font-medium transition-colors"
            :style="
              isPreviewMode
                ? 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg); border: none;'
                : 'color: var(--semantic-text); border: 1px solid var(--color-border); opacity: 0.8;'
            "
            :title="
              isPreviewMode
                ? 'Exit Preview mode (shortcut: Esc)'
                : 'Preview the mockup — type into inputs, click buttons (shortcut: Cmd/Ctrl+P)'
            "
            :aria-label="isPreviewMode ? 'Exit Preview mode' : 'Enter Preview mode'"
            :aria-pressed="isPreviewMode"
            data-testid="design-preview-toggle"
            @click="togglePreviewMode"
          >
            <span aria-hidden="true">{{ isPreviewMode ? '■ ' : '▶ ' }}</span
            >Preview
          </button>
          <div
            class="flex items-center gap-1 shrink-0"
            data-testid="design-zoom-toolbar"
            :title="`Zoom (Ctrl+wheel or trackpad pinch) — currently ${Math.round(zoom * 100)}%`"
          >
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border)"
              aria-label="Zoom out (Ctrl+wheel down)"
              title="Zoom out (Ctrl+wheel down)"
              data-testid="design-zoom-out"
              @click="zoomOut"
            >
              −
            </button>
            <button
              type="button"
              class="px-2 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80 min-w-[3.5rem] text-center"
              style="color: var(--semantic-text); border: 1px solid var(--color-border)"
              :title="`Reset zoom (currently ${Math.round(zoom * 100)}%)`"
              aria-label="Reset zoom"
              data-testid="design-zoom-reset"
              @click="zoomReset"
            >
              {{ Math.round(zoom * 100) }}%
            </button>
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border)"
              aria-label="Fit page to viewport (shortcut: F or Shift+1)"
              title="Fit page to viewport (F or Shift+1)"
              data-testid="design-zoom-fit"
              @click="zoomFit"
            >
              ⛶
            </button>
            <button
              type="button"
              class="px-1.5 py-0.5 rounded text-dense font-medium hover:opacity-100 opacity-80"
              style="color: var(--semantic-text); border: 1px solid var(--color-border)"
              aria-label="Zoom in (Ctrl+wheel up)"
              title="Zoom in (Ctrl+wheel up)"
              data-testid="design-zoom-in"
              @click="zoomIn"
            >
              +
            </button>
          </div>
        </div>

        <!-- Canvas viewport -->
        <div
          class="flex-1 overflow-auto min-h-0"
          style="background-color: var(--color-bg-m2); touch-action: pan-x pan-y"
          data-testid="design-canvas-scroll-container"
          @click="handleCanvasClick"
          @wheel="handleCanvasWheel"
          @pointerdown="onPinchPointerDown"
          @pointermove="onPinchPointerMove"
          @pointerup="onPinchPointerEnd"
          @pointercancel="onPinchPointerEnd"
        >
          <div
            class="relative mx-auto my-6 origin-top-left"
            :style="{
              minWidth: '1440px',
              minHeight: '1024px',
              transform: `scale(${zoom})`,
            }"
            data-testid="design-canvas"
            @click.stop
            @contextmenu="handleCanvasContextMenu"
          >
            <DesignElement
              v-for="element in elements"
              :key="element.id"
              :element="element"
              :selected="isSingleSelect && activeElements[0]?.id === element.id"
              :selected-ids="Array.from(selectedIds)"
              :readonly="false"
              :zoom="zoom"
              :workspace-id="workspaceId"
              :item-id="itemId || item.id"
              :page-id="activePageId"
              :preview-mode="isPreviewMode"
              @select="(payload) => handleElementToggle(payload.elementId, payload.additive)"
              @update="handleElementUpdate"
              @translate="handleElementTranslate"
              @resize="handleElementResize"
              @group-drag="handleGroupDrag"
              @drag-end="handleDragEnd"
              @drag-start="handleDragStart"
              @html-changed="handleElementHtmlChanged"
              @delete="handleElementDelete"
            />
            <!--
              Snap guides (Chunk 3): SVG overlay rendered ABOVE the
              elements (z-index higher in DOM order) but BELOW the
              resize handles (which are inside each DesignElement).
              `pointer-events-none` so the SVG never intercepts the
              cursor — the canvas's own pointer handlers stay alive.
              1px violet lines: vertical = x-axis guides at a fixed
              position, full canvas height; horizontal = y-axis guides,
              full canvas width.

              The SVG fills the canvas div (which is now auto-grow,
              wrapping all elements). Guide line endpoints use `100%`
              so the lines span the full canvas div height/width
              regardless of the actual element positions.
            -->
            <svg
              v-if="snapGuides.length > 0"
              class="absolute inset-0 pointer-events-none"
              width="100%"
              height="100%"
              data-testid="design-snap-guides"
              aria-hidden="true"
            >
              <line
                v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'x')"
                :key="`x-${idx}`"
                :x1="guide.position"
                :y1="0"
                :x2="guide.position"
                y2="100%"
                stroke="var(--color-violet)"
                stroke-width="1"
              />
              <line
                v-for="(guide, idx) in snapGuides.filter((g) => g.axis === 'y')"
                :key="`y-${idx}`"
                :x1="0"
                :y1="guide.position"
                x2="100%"
                :y2="guide.position"
                stroke="var(--color-violet)"
                stroke-width="1"
              />
            </svg>
            <!-- Element-fetch skeleton — holds the canvas's height while
                 the page's elements load, so the "Click + Element" empty
                 state does not flash first. -->
            <div
              v-if="isElementsLoading"
              class="absolute inset-0 flex items-center justify-center pointer-events-none"
              data-testid="design-canvas-skeleton"
              role="status"
              aria-label="Loading elements"
            >
              <div class="w-full max-w-md space-y-3 px-8">
                <div
                  v-for="w in ['100%', '72%', '88%', '60%']"
                  :key="w"
                  class="h-10 rounded animate-pulse"
                  :style="{ width: w, backgroundColor: 'var(--semantic-active-bg)' }"
                ></div>
              </div>
            </div>
            <div
              v-else-if="elements.length === 0"
              class="absolute inset-0 flex items-center justify-center text-body pointer-events-none"
              style="color: var(--semantic-text-dim)"
              data-testid="design-canvas-empty"
            >
              <div class="text-center">
                <div class="text-display mb-2" aria-hidden="true">▢</div>
                <div>Click "+ Element" to add your first element</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Resize handle (canvas ↔ right sidebar) -->
      <div
        class="shrink-0 w-2 cursor-col-resize relative flex items-center justify-center transition-colors"
        :class="
          isSidebarResizing
            ? '!bg-[var(--color-violet)]/60'
            : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
        "
        data-testid="design-sidebar-resize-handle"
        title="Drag to resize"
        @mousedown="startSidebarResize"
      >
        <svg
          width="14"
          height="2"
          viewBox="0 0 14 2"
          fill="currentColor"
          class="text-[var(--color-violet)] opacity-70"
          aria-hidden="true"
        >
          <circle cx="3" cy="1" r="1" />
          <circle cx="7" cy="1" r="1" />
          <circle cx="11" cy="1" r="1" />
        </svg>
      </div>

      <!-- Right sidebar (Layers + Properties) -->
      <div
        class="shrink-0 flex flex-col h-full min-h-0"
        :style="{ width: `${sidebarWidth}px` }"
        data-testid="design-right-sidebar"
      >
        <!-- Layers (top, flexible height by layersHeightRatio) -->
        <div class="min-h-0 overflow-hidden" :style="{ height: `${layersHeightRatio * 100}%` }">
          <LayersPanel
            :elements="elements"
            :selected-ids="Array.from(selectedIds)"
            :readonly="isPreviewMode"
            @select="handleLayerSelect"
            @reparent="handleLayerReparent"
            @reorder="handleReorderElements"
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
          />
        </div>

        <!-- Horizontal resize handle between Layers and Properties -->
        <div
          class="shrink-0 h-2 cursor-row-resize transition-colors"
          :class="
            isLayersResizing
              ? '!bg-[var(--color-violet)]/60'
              : 'bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40'
          "
          data-testid="design-layers-resize-handle"
          title="Drag to resize"
          @mousedown="startLayersResize"
        />

        <!-- Properties (bottom, fills remaining height) -->
        <div class="flex-1 min-h-0 overflow-hidden">
          <PropertiesPanel
            :elements="activeElements"
            :readonly="false"
            :preview-mode="isPreviewMode"
            @update="handlePropertiesUpdate"
            @html-changed="handlePropertiesHtmlChanged"
            @delete="handlePropertiesDelete"
          />
        </div>
      </div>
    </div>

    <!-- ─── Add element dialog ───────────────────────────────────── -->
    <AddDesignElementDialog
      :show="showAddElementDialog"
      :page-id="activePageId"
      :readonly="false"
      @create="handleCreateElement"
      @close="showAddElementDialog = false"
    />

    <!-- ─── Canvas right-click context menu (Chunk 3+5+9) ────────────
         Disabled in Preview mode (the canvasContextMenu composable
         keeps `visible: false` because handleCanvasContextMenu
         short-circuits there). -->
    <DesignContextMenu
      :visible="canvasContextMenu.state.value.visible"
      :x="canvasContextMenu.state.value.x"
      :y="canvasContextMenu.state.value.y"
      :target-ids="canvasContextMenu.state.value.targetIds"
      :elements="elements"
      @group="handleDesignGroupFromContextMenu"
      @ungroup="handleDesignUngroupFromContextMenu"
      @leave-group="handleDesignLeaveGroupFromContextMenu"
      @select-all="handleDesignSelectAll"
      @move-to-page="handleDesignMoveToPageFromContextMenu"
      @bring-to-front="() => dispatchReorder('bring_to_front')"
      @bring-forward="() => dispatchReorder('bring_forward')"
      @send-backward="() => dispatchReorder('send_backward')"
      @send-to-back="() => dispatchReorder('send_to_back')"
      @delete="handleDesignContextMenuDelete"
      @close="canvasContextMenu.close()"
    />

    <!-- NEW (2026-08-06, design-move-to-page plan, Chunk 8): centred
         modal for choosing the target page when the user clicks
         "Move to page..." in the right-click menu. Mounted at the
         AppLayout-equivalent level so it escapes the canvas's
         transform/overflow contexts.
         Pages list comes from workspacesStore.designPagesByItemId
         (single source of truth shared with the sidebar tree). -->
    <MoveToPageDialog
      :visible="moveToPageDialogVisible"
      :element-name="elementNameForMoveDialog"
      :current-page-id="activePageId"
      :pages="pagesForMoveDialog"
      @close="handleDesignMoveToPageDialogClose"
      @select="handleDesignMoveToPageDialogSelect"
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

import { computed, ref, type ComputedRef, type Ref } from 'vue'
import type { DesignElement as DesignElementApi } from '../../api'
import type { useDesignHandlers } from '../../composables/useDesignHandlers'
import type { useWorkspacesStore, Task as TaskType, Workspace, WorkspaceItem } from '../../stores/workspaces'

type DesignPanelDeps = {
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  designHandlers: ReturnType<typeof useDesignHandlers>
  activeWorkspaceItem: ComputedRef<WorkspaceItem | undefined>
  activeWorkspace: ComputedRef<Workspace | undefined>
}

export interface UseDesignPanelReturn {
  activeDesignChatPageName: Ref<string>
  activeDesignChatTaskId: Ref<string>
  activeDesignChatTask: ComputedRef<TaskType | null>
  designChatDialogOpen: ComputedRef<boolean>
  handleDesignSelectPage: (pageId: string) => void
  handleDesignSelectElement: (elementId: string) => void
  handleDesignOpenChat: (payload: {
    pageId: string
    pageName: string
    workspaceItemTaskId: string
  }) => Promise<void>
  handleDesignUpdateElement: (
    elementId: string,
    patch: Partial<{
      x: number
      y: number
      width: number
      height: number
      rotation: number
      [k: string]: unknown
    }>,
  ) => Promise<void>
  handleDesignTranslateElement: (elementId: string, dx: number, dy: number) => Promise<void>
  handleDesignResizeElement: (
    elementId: string,
    patch: Partial<{
      x: number
      y: number
      width: number
      height: number
      rotation: number
      [k: string]: unknown
    }>,
  ) => Promise<void>
  handleDesignDeleteElement: (elementId: string) => Promise<void>
  handleDesignCreateElement: (body: {
    name: string
    type: DesignElementApi['type']
    html: string
  }) => Promise<void>
}

/** Design mode: the chat dialog's identity refs plus the canvas mutation handlers DesignView emits. */
export function useDesignPanel(deps: DesignPanelDeps): UseDesignPanelReturn {
  const { workspacesStore, designHandlers, activeWorkspaceItem, activeWorkspace } = deps

// ─── Kanban task chat ────────────────────────────────────────────────────────
const activeDesignChatPageName = ref<string>('')

// ─── Design chat task FK handle (plan: 2026-08-06-design-chat-as-dialog, bug fix from user report "the chat button keep not popup, chatview") ──── Root cause …
const activeDesignChatTaskId = ref<string>('')
// The store's `activeTaskId` going falsy clears the design-chat refs so the dialog unmounts.
const activeDesignChatTask = computed<TaskType | null>(() => {
  if (!activeDesignChatTaskId.value) return null
  return {
    id: activeDesignChatTaskId.value,
    name: activeDesignChatPageName.value
      ? `Design Chat: ${activeDesignChatPageName.value}`
      : 'Design Chat',
    description: '',
    taskType: 'standard',
  } as TaskType
})

// ─── DesignChatDialog open state (plan: 2026-08-06-design-chat-as-dialog) ────
const designChatDialogOpen = computed({
  get: () => !!activeDesignChatTaskId.value,
  // The dialog can only ask to close (it never opens itself).
  set: (open: boolean) => {
    if (!open) activeDesignChatTaskId.value = ''
  },
})

// ─── Design mode event handlers (Chunk 8 of design-mode-redesign) ────
const handleDesignSelectPage = (_pageId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignPage(_pageId) once the store tracks the active page.
  void _pageId
}

const handleDesignSelectElement = (_elementId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignElement(_elementId) so other tabs / the right sidebar can show the element's properties.
  void _elementId
}

// NEW: design-mode chat toggle (top-right 💬 button in DesignView).Migration of legacy data
const handleDesignOpenChat = async (payload: {
  pageId: string
  pageName: string
  workspaceItemTaskId: string
}): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item || item.item_type !== 'design') return
  if (!payload.pageId || !payload.pageName) return
  if (!payload.workspaceItemTaskId) return

  // 2026-07-28 FK rewrite: resolve the chat task via the FK directly.
  workspacesStore.setActiveTask(payload.workspaceItemTaskId)
  // 2026-08-06 (plan: design-chat-as-dialog): capture the design page's own name so DesignChatDialog's header reads "Design Chat: <pageName>".
  activeDesignChatPageName.value = payload.pageName
  // Bug fix (2026-08-06, user report "chat button keep not popup, chatview"): the dialog's v-if was previously gated on the store's `activeTask` computed, which is …
  activeDesignChatTaskId.value = payload.workspaceItemTaskId
}

const handleDesignUpdateElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  // Deprecated back-compat path (PATCH /geometry).
  await designHandlers.updateElement(ws.id, item.id, elementId, patch)
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the `translateElement` event fired by DesignView during a single-element drag (move mode). */
const handleDesignTranslateElement = async (
  elementId: string,
  dx: number,
  dy: number,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.translateElement(ws.id, item.id, elementId, dx, dy)
}

/** NEW (2026-08-06, split-move-resize plan) — handler for the `resizeElement` event fired by DesignView during a resize gesture. */
const handleDesignResizeElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.resizeElement(ws.id, item.id, elementId, patch)
}

const handleDesignDeleteElement = async (elementId: string): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.deleteElement(ws.id, item.id, elementId)
}

/** NEW (regression fix, 2026-08-14, "design mode, add element manual not working"). */
const handleDesignCreateElement = async (body: {
  name: string
  type: DesignElementApi['type']
  html: string
}): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.createElement(ws.id, item.id, body)
}

  return {
    activeDesignChatPageName,
    activeDesignChatTaskId,
    activeDesignChatTask,
    designChatDialogOpen,
    handleDesignSelectPage,
    handleDesignSelectElement,
    handleDesignOpenChat,
    handleDesignUpdateElement,
    handleDesignTranslateElement,
    handleDesignResizeElement,
    handleDesignDeleteElement,
    handleDesignCreateElement,
  }
}

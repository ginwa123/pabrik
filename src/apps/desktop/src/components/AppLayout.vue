<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, provide } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './shell/Sidebar.vue'
import GitFileViewer from './git/GitFileViewer.vue'
import Chats from './views/Chats.vue'
import CodeViewerStage from './views/CodeViewerStage.vue'
import DesignChatDialog from './design/DesignChatDialog.vue'
import AgentKnowledgeDialog from './dialogs/AgentKnowledgeDialog.vue'
import AgentSystemPromptDialog from './dialogs/AgentSystemPromptDialog.vue'
import AgentKnowledgeDetailDialog from './dialogs/AgentKnowledgeDetailDialog.vue'
import KanbanColumnEditor from './kanban/KanbanColumnEditor.vue'
import ConfirmDialog from './dialogs/ConfirmDialog.vue'
import CopyKanbanSpecDialog from './dialogs/CopyKanbanSpecDialog.vue'
import * as api from '../api'
import { useNavigationStore } from '../stores/navigation'
import { useTabsStore } from '../stores/tabs'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import {
  CODE_VIEWER_STATE_KEY, OPEN_IN_CODE_EDITOR_KEY, type CodeViewerState, type OpenInCodeEditorFn,
} from '../composables/useCodeEditor'
import { useCodeEditorSession } from '../composables/useCodeEditorSession'
import { useDesignHandlers } from '../composables/useDesignHandlers'
import { useCurrentMainView } from '../composables/useCurrentMainView'
import { mount as mountFpsOverlay, unmount as unmountFpsOverlay } from '../helpers/fpsOverlay'
import { parseAppPath } from '../helpers/appUrl'
import { codeEditorQuery } from './appLayout/codeEditorUrl'
import { resolveOverlayView, resolvePathView } from './appLayout/appViewResolvers'
import { useChatSessionCwd } from './appLayout/useChatSessionCwd'
import { useAppLayoutOverlays } from './appLayout/useAppLayoutOverlays'
import { useAppLayoutBootUrl } from './appLayout/useAppLayoutBootUrl'
import { useAppLayoutUrlState } from './appLayout/useAppLayoutUrlState'
import { useAppLayoutSse } from './appLayout/useAppLayoutSse'
import { useDesignPanel } from './appLayout/useDesignPanel'
import { useAgentPanel } from './appLayout/useAgentPanel'
import { useAgentPrompts } from './appLayout/useAgentPrompts'
import { useAppLayoutTabs } from './appLayout/useAppLayoutTabs'
import { useAppLayoutNavigation } from './appLayout/useAppLayoutNavigation'
import { useKanbanPanel } from './appLayout/useKanbanPanel'
import { useKanbanCardEvents } from './appLayout/useKanbanCardEvents'
import { useAppLayoutRouteSync } from './appLayout/useAppLayoutRouteSync'
import { useAppLayoutPumps } from './appLayout/useAppLayoutPumps'
import AppSkillOverlay from './appLayout/AppSkillOverlay.vue'
import AppDocumentsBranch from './appLayout/AppDocumentsBranch.vue'
import AppKanbanSettingsBranch from './appLayout/AppKanbanSettingsBranch.vue'
import AppKanbanBoardBranch from './appLayout/AppKanbanBoardBranch.vue'
import AppKanbanChatBranch from './appLayout/AppKanbanChatBranch.vue'
import AppDesignBranch from './appLayout/AppDesignBranch.vue'
import AppAgentViewBranch from './appLayout/AppAgentViewBranch.vue'
import AppAgentChatBranch from './appLayout/AppAgentChatBranch.vue'
import AppRoutineBranch from './appLayout/AppRoutineBranch.vue'
import AppStandardTaskChatBranch from './appLayout/AppStandardTaskChatBranch.vue'
import AppStandaloneChatBranch from './appLayout/AppStandaloneChatBranch.vue'
import AppWorkspacePreview from './appLayout/AppWorkspacePreview.vue'
import AppLayoutChrome from './appLayout/AppLayoutChrome.vue'

const router = useRouter()
const route = useRoute()
const navigationStore = useNavigationStore()
const tabsStore = useTabsStore()
const workspacesStore = useWorkspacesStore()
// URL-derived main view (path-based contract) — used by navigations
// that need the current workspace without reading store flags.
const currentMainView = useCurrentMainView()
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const sidebarStore = useSidebarStore()

// Ref to Sidebar component
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)
const activeWorkspace = computed(() => workspacesStore.activeWorkspace)
const activeWorkspaceId = computed(() => activeWorkspace.value?.id ?? '')
const activeTask = computed(() => workspacesStore.activeTask)
// Workspace-item id of the currently-active task. Used by the 3-column kanban|chatview template
// branch to make sure the chatview and the kanban belong to the same parent — otherwise we'd render
// a chatview of a non-kanban task alongside an unrelated kanban (visual mess).
const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)
const activeChatId = computed(() => navigationStore.activeChatId)
const activeChatName = computed(() => navigationStore.activeChatName)
const sidebarCollapsed = computed(() => navigationStore.sidebarCollapsed)
const sidebarWidth = computed(() => navigationStore.sidebarWidth)
const { chatSessionCwd, fetchChatSessionCwd } = useChatSessionCwd(navigationStore)

// Right sidebar cwd - show when chat is open OR task is active
const rightSidebarCwd = computed(() => {
  if (activeTask.value && activeWorkspaceItem.value?.path) return activeWorkspaceItem.value.path
  if (navigationStore.activeChatId && navigationStore.activeChatId.startsWith('chat-')) {
    return chatSessionCwd.value || activeWorkspaceItem.value?.path || ''
  }
  return ''
})
// Effective cwd for the <ChatView> mount. The ChatView child seeds its `sessionCwd` ref from this
// prop in onMounted (`if (props.cwd) sessionCwd.value = props.cwd`), then sends it as `cwd_session`
// on every api.sendChatMessage call.
const effectiveChatCwd = computed(() => chatSessionCwd.value || activeWorkspaceItem.value?.path || '')

// Dev-only FPS overlay (desktop scroll-perf plan, Task 5): lets us measure platform rendering fixes
// (Linux gfx pinning, macOS scheme handler, Windows resize coalescing) in the running app. mount()
// is a no-op in prod builds; unmount on teardown keeps HMR clean.
onMounted(() => mountFpsOverlay())
onUnmounted(() => unmountFpsOverlay())

// Code editor session — single source of truth for the open-file flow (file / content / loading /
// error / requested line / cwd).
const codeEditorSession = useCodeEditorSession({
  readFile: (cwd, path) => api.readFileContent(cwd, path),
  syncUrl: ({ path, line }) => {
    router.replace({ path: route.path, query: codeEditorQuery(route.query, path, line) })
  },
})

const overlays = useAppLayoutOverlays({
  router, route, workspacesStore, currentMainView, codeEditorSession, activeChatId, activeTask,
  activeWorkspaceId, chatSessionCwd, rightSidebarCwd,
})
const {
  gitViewerFile, gitViewerStaged, skillViewerSkill, closeGitViewer,
  closeSkillViewer, closeCodeEditor, handleSubmitReview, clearAllOverlays,
  retryEditorRestore, openInCodeEditor,
} = overlays

// Template and view bindings keep their names — they alias the
// session refs (same objects, no duplicated state).
const codeEditorFile = codeEditorSession.file
const codeEditorContent = codeEditorSession.content
const codeEditorLoading = codeEditorSession.loading
const codeEditorError = codeEditorSession.error
const codeEditorRequestedLine = codeEditorSession.requestedLine

// Expose openInCodeEditor to all descendants (tool output components) via inject
provide<OpenInCodeEditorFn>(OPEN_IN_CODE_EDITOR_KEY, openInCodeEditor)

// The open file itself, so a SURFACE can render it: ChatView paints it in its center column next to
// the chat-owned right sidebar (the user opened the file FROM that sidebar.
const codeViewerState: CodeViewerState = {
  file: codeEditorSession.file,
  content: codeEditorSession.content,
  loading: codeEditorSession.loading,
  error: codeEditorSession.error,
  requestedLine: codeEditorSession.requestedLine,
  cwd: codeEditorSession.cwd,
  close: closeCodeEditor,
}
provide<CodeViewerState>(CODE_VIEWER_STATE_KEY, codeViewerState)

const { handleBootUrl } = useAppLayoutBootUrl({
  router, route, workspacesStore, navigationStore, codeEditorSession, fetchChatSessionCwd,
  rightSidebarCwd,
})
// Settings overlay state (now driven by route)
onMounted(() => {
  void handleBootUrl()
})

const { pendingUrlRestore, restoreUrlState, syncItemToUrl } = useAppLayoutUrlState({
  router, route, workspacesStore,
})

const { initSseStores, closeSse } = useAppLayoutSse()
onUnmounted(() => closeSse())

// NEW (Chunk 1, Task 1.3 of design-element-drag-and-drop plan). Extracted handlers so they're
// directly unit-testable.
const designHandlers = useDesignHandlers()
const designPanel = useDesignPanel({ workspacesStore, designHandlers, activeWorkspaceItem, activeWorkspace })
const {
  activeDesignChatPageName, activeDesignChatTaskId, activeDesignChatTask, designChatDialogOpen,
} = designPanel

const agentPanel = useAgentPanel({ activeWorkspaceItem, activeWorkspace })
const {
  agentKnowledge, agentTools, agentSystemPrompts, agentDataLoading, maybeLoadAgentData,
  agentKnowledgeDialogOpen, agentKnowledgeError, agentKnowledgeBusy, handleAgentAddKnowledge,
  closeAgentKnowledgeDialog, handleAgentKnowledgeCreate, handleAgentRemoveKnowledge,
  agentKnowledgeDetailOpen, agentKnowledgeDetailRow, agentKnowledgeDetailBusy,
  agentKnowledgeDetailError, handleAgentEditKnowledge, closeAgentKnowledgeDetailDialog,
  handleAgentKnowledgeSave,
} = agentPanel

const promptsPanel = useAgentPrompts({
  activeWorkspaceItem, agentTools: agentPanel.agentTools,
  agentSystemPrompts: agentPanel.agentSystemPrompts,
})
const {
  agentSystemPromptDialogOpen, agentSystemPromptRow, agentSystemPromptBusy, agentSystemPromptError,
  handleAgentAddSystemPrompt, handleAgentEditSystemPrompt, closeAgentSystemPromptDialog,
  handleAgentSystemPromptCreate, handleAgentSystemPromptSave, handleAgentRemoveSystemPrompt,
  handleAgentToggleTool, handleAgentToggleToolsBulk,
} = promptsPanel

const tabs = useAppLayoutTabs({ router, route, workspacesStore, navigationStore, tabsStore })

const navigation = useAppLayoutNavigation({
  router, route, workspacesStore, navigationStore, tabsStore, sidebarRef, chatSessionCwd,
  activeChatId, activeWorkspaceItem, activeWorkspaceId, chatTarget: overlays.chatTarget,
  clearAllOverlays, fetchChatSessionCwd, applyActiveTabToUrl: tabs.applyActiveTabToUrl,
})
const { handleNavigate, handleSelectWorkspace, handleUpdateChatId, handleCloseTaskView } = navigation

const kanban = useKanbanPanel({ router, workspacesStore, activeWorkspaceItem, activeWorkspace })
const { showKanbanColumnEditor, kanbanColumnEditorMode, kanbanColumnEditorInitialName,
  kanbanColumnEditorInitialDescription, kanbanColumnEditorInitialIsDone, showCopyKanbanSpecDialog,
  showMoveBlockedConfirm, moveBlockedMessage, handleKanbanMoveTask, handleMoveBlockedConfirm,
  handleMoveBlockedClose, handleKanbanAddColumn, handleKanbanRequestRenameColumn,
  handleKanbanRequestDeleteColumn, handleKanbanRenameItem, handleOpenKanbanSettings,
  handleKanbanSettingsAddColumn, handleKanbanSettingsEditColumn, handleKanbanSettingsDeleteColumn,
  handleKanbanColumnEditorClose, handleKanbanColumnEditorAdd, handleKanbanColumnEditorRename,
  handleKanbanColumnEditorDelete, handleOpenCopyKanbanSpec, handleCloseCopyKanbanSpec,
  handleCopyKanbanSpec } = kanban
const {
  handleKanbanRenameColumn, handleKanbanDeleteColumn, handleKanbanReorderColumn,
  handleKanbanSelectTask, handleKanbanOpenTaskInBackground, handleKanbanOpenTaskDetailInBackground,
  handleKanbanDeleteTask, handleKanbanRenameTask, handleKanbanPinTask,
} = useKanbanCardEvents({
  router, route, workspacesStore, sidebarRef, activeWorkspaceItem, activeWorkspace,
})

const toggleSidebar = () => navigationStore.toggleSidebar()

const handleSidebarResize = (newWidth: number) => navigationStore.setSidebarWidth(newWidth)

const { syncTaskFromItemId, reconcileRoute } = useAppLayoutRouteSync({
  route, workspacesStore, navigationStore, tabsStore, codeEditorSession, activeChatId, chatSessionCwd,
  rightSidebarCwd, gitViewerFile, gitViewerStaged, skillViewerSkill, clearAllOverlays,
  fetchChatSessionCwd,
})

// The open document's id, read from the PATH rather than `route.params.documentId`.
const activeDocumentId = computed(() => {
  const parsed = parseAppPath(route.path)
  return parsed.kind === 'doc' ? parsed.documentId : ''
})

// The board the settings page shows: the item id the URL names — the project id on the
// workspace-scoped path, the legacy `:itemId` param on the old kanban path.
const kanbanSettingsItemId = computed(() => {
  const parsed = parseAppPath(route.path)
  if (parsed.kind === 'projectSettings') return parsed.projectId
  const legacy = route.params.itemId
  return typeof legacy === 'string' ? legacy : ''
})

/** True when the <main> chain is showing a ChatView surface — i.e. when ChatView owns the center
 * column AND the chat-owned right sidebar (Explorer / Files changed / Terminal). Single source of
 * truth for the three call sites that must agree: 1. */
const chatSurfaceActive = computed(() => {
  const item = activeWorkspaceItem.value
  if (item?.item_type === 'design') return false
  if (activeTask.value && activeTaskWorkspaceItemId.value === item?.id) return true
  return activeChatId.value.startsWith('chat-')
})

const currentView = computed(() => {
  const overlay = resolveOverlayView(route.path, !!gitViewerFile.value, !!skillViewerSkill.value)
  if (overlay) return overlay
  // code-editor view - the open file wins UNLESS a chat surface can display it itself. See
  // `chatSurfaceActive`.
  if (codeEditorFile.value && !chatSurfaceActive.value) return 'code-editor'
  return resolvePathView(route.path, route.query.view as string | undefined)
})

useAppLayoutPumps({
  route, workspacesStore, navigationStore, activeWorkspaceId, rightSidebarCwd,
  activeDesignChatTaskId, activeDesignChatPageName, pendingUrlRestore, clearAllOverlays,
  initSseStores, syncItemToUrl, maybeLoadAgentData, restoreUrlState, retryEditorRestore,
  syncTaskFromItemId, reconcileRoute, syncFromRoute: tabs.syncFromRoute,
  isTabsFunnelReady: tabs.isTabsFunnelReady,
})

// Expose the design chat open handler so tests can simulate the user clicking the 💬 button in
// DesignView (which emits `openChat`). In production, this is reached via the DesignView emit chain
// — tests don't render DesignView because they stub it.
defineExpose({
  handleDesignOpenChat: designPanel.handleDesignOpenChat,
  handleDesignCreateElement: designPanel.handleDesignCreateElement,
  applyActiveTabToUrl: tabs.applyActiveTabToUrl,
  mirrorTargetIntoStores: tabs.mirrorTargetIntoStores,
  syncFromRoute: tabs.syncFromRoute,
  handleUpdateChatId,
})
</script>

<template>
  <div class="flex flex-col h-screen" style="background-color: var(--semantic-content-bg)">
    <!-- The row of columns. It is a wrapper so the terminal footer can sit
         BELOW the sidebar and the main view: the footer belongs to the
         window, not to one column. -->
    <div class="flex flex-1 min-h-0">
    <Sidebar
      ref="sidebarRef" @navigate="handleNavigate" @select-workspace="handleSelectWorkspace"
      :collapsed="sidebarCollapsed" :width="sidebarWidth" @toggle-collapse="toggleSidebar"
      @resize="handleSidebarResize"
    />
    <main class="flex-1 flex flex-col overflow-hidden relative">
      <!-- Git File Viewer (shown when view is gitfile) -->
      <GitFileViewer
        v-if="currentView === 'gitfile' && gitViewerFile && rightSidebarCwd"
        class="absolute inset-0" style="z-index: 10" :cwd="rightSidebarCwd"
        :file-path="gitViewerFile.path" :staged="gitViewerStaged"
        :file-name="gitViewerFile.path.split('/').pop() || gitViewerFile.path"
        @close="closeGitViewer" @submit-review="handleSubmitReview"
        @comment-saved="overlays.handleCommentSaved"
      />

      <!-- Skill Detail Viewer (shown when view is skill) -->
      <AppSkillOverlay
        v-if="currentView === 'skill' && skillViewerSkill"
        :skill-name="skillViewerSkill?.name"
        @close="closeSkillViewer"
      />

      <!-- Code viewer — full-surface FALLBACK. `currentView` only resolves
           to 'code-editor' when no ChatView is on screen (see
           `chatSurfaceActive`), because inside a chat the viewer renders
           in ChatView's center column so the chat-owned right sidebar
           (Explorer / Files changed / Terminal) stays visible. Same
           `CodeViewerStage` component, so both surfaces are identical. -->
      <div
        v-if="currentView === 'code-editor' && codeEditorFile"
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10"
        data-testid="code-viewer-overlay"
      >
        <CodeViewerStage
          :file="codeEditorFile"
          :content="codeEditorContent"
          :loading="codeEditorLoading"
          :error="codeEditorError"
          :cwd="rightSidebarCwd"
          :line="codeEditorRequestedLine"
          @close="closeCodeEditor"
        />
      </div>

      <AppDocumentsBranch
        v-else-if="currentView === 'documents' && activeDocumentId"
        :key="'doc-' + activeDocumentId"
        :document-id="activeDocumentId"
      />
      <AppKanbanSettingsBranch
        v-else-if="currentView === 'kanban-settings'"
        :key="'kanban-settings-' + kanbanSettingsItemId"
        :item-id="kanbanSettingsItemId"
        @add-column="handleKanbanSettingsAddColumn"
        @edit-column="handleKanbanSettingsEditColumn"
        @delete-column="handleKanbanSettingsDeleteColumn"
        @rename-item="handleKanbanRenameItem"
        @copy-spec="handleOpenCopyKanbanSpec"
      />
      <AppKanbanChatBranch
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'kanban' &&
          activeTask &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        :key="'kanban-chat-' + activeTask.id"
        :task="activeTask"
        :cwd="effectiveChatCwd"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <AppKanbanBoardBranch
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
        :key="'kanban-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        @move-task="handleKanbanMoveTask"
        @add-column="handleKanbanAddColumn"
        @rename-column="handleKanbanRenameColumn"
        @delete-column="handleKanbanDeleteColumn"
        @reorder-column="handleKanbanReorderColumn"
        @request-rename-column="handleKanbanRequestRenameColumn"
        @request-delete-column="handleKanbanRequestDeleteColumn"
        @select-task="handleKanbanSelectTask"
        @open-task-in-background="handleKanbanOpenTaskInBackground"
        @open-task-detail-in-background="handleKanbanOpenTaskDetailInBackground"
        @delete-task="handleKanbanDeleteTask"
        @rename-task="handleKanbanRenameTask"
        @pin-task="handleKanbanPinTask"
        @open-settings="handleOpenKanbanSettings"
        @rename-item="handleKanbanRenameItem"
        @close-chat="handleCloseTaskView"
      />
      <!--
        Design chat dialog (plan: 2026-08-06-design-chat-as-dialog).
        Same Teleport pattern as the kanban task chat used to have, and
        the same v-model:show binding driven by `activeDesignChatTaskId`.
        This `v-if` (not `v-else-if`) starts its own chain — that is
        deliberate and pre-existing: DesignView's `v-else-if` below
        attaches to THIS element, not to the kanban chain above.
        Mounted at the AppLayout level (NOT inside DesignView) so the
        chat opens as a centred modal overlay rather than a side-by-
        side column. Gated on `item_type === 'design'` so the dialog
        only opens for design items — kanban / folder / standalone
        chat use their own mounts. The pre-fix design+chat 3-column
        branch (data-design-three-column) was removed; the dialog
        reclaims the full canvas width. URL routing is handled by
        AppLayout's existing handleCloseTaskView (re-used via @close).
      -->
      <DesignChatDialog
        v-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'design' &&
          activeDesignChatTaskId
        "
        v-model:show="designChatDialogOpen"
        :task="activeDesignChatTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :page-name="activeDesignChatPageName"
        :project-name="activeWorkspace?.name ?? ''"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
      <AppDesignBranch
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"
        :key="'design-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        @select-page="designPanel.handleDesignSelectPage"
        @select-element="designPanel.handleDesignSelectElement"
        @create-element="designPanel.handleDesignCreateElement"
        @update-element="designPanel.handleDesignUpdateElement"
        @translate-element="designPanel.handleDesignTranslateElement"
        @resize-element="designPanel.handleDesignResizeElement"
        @delete-element="designPanel.handleDesignDeleteElement"
        @open-chat="designPanel.handleDesignOpenChat"
      />
      <AppAgentChatBranch
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'agent' &&
          activeTask &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        :key="'agent-chat-' + activeTask.id"
        :task="activeTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
      <AppAgentViewBranch
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :key="'agent-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :knowledge="agentKnowledge"
        :tools="agentTools"
        :system-prompts="agentSystemPrompts"
        :parent-loading="agentDataLoading"
        @add-knowledge="handleAgentAddKnowledge"
        @remove-knowledge="handleAgentRemoveKnowledge"
        @edit-knowledge="handleAgentEditKnowledge"
        @toggle-tool="handleAgentToggleTool"
        @toggle-tools-bulk="(names: string[], enabled: boolean) => handleAgentToggleToolsBulk(names, enabled)"
        @add-system-prompt="handleAgentAddSystemPrompt"
        @edit-system-prompt="handleAgentEditSystemPrompt"
        @remove-system-prompt="handleAgentRemoveSystemPrompt"
      />
      <AppRoutineBranch
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'routine'"
        :key="'routine-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
      />
      <!--
        AgentKnowledgeDialog — mounted at the AppLayout level so the
        AgentView's `+ Add` button emits up to open this dialog. Uses
        the same v-model:show pattern as the knowledge dialogs below.
        Gated on `item_type === 'agent'` so the dialog only opens
        while an agent item is active. The agent id == workspace item
        id per Migration 076 (agents.id is the workspace_item_id).
      -->
      <AgentKnowledgeDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        v-model:show="agentKnowledgeDialogOpen"
        :busy="agentKnowledgeBusy"
        :error="agentKnowledgeError"
        @close="closeAgentKnowledgeDialog"
        @create="handleAgentKnowledgeCreate"
      />
      <!--
        AgentKnowledgeDetailDialog — edit mode for an existing knowledge
        row (plan 2026-08-22-agent-mode-ui-ux, A2). Opened by AgentView's
        per-row ✎ button via the `edit-knowledge` emit. Same v-model:show
        + busy/error pattern as the add dialog above.
      -->
      <AgentKnowledgeDetailDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :show="agentKnowledgeDetailOpen"
        :row="agentKnowledgeDetailRow"
        :busy="agentKnowledgeDetailBusy"
        :error="agentKnowledgeDetailError"
        @close="closeAgentKnowledgeDetailDialog"
        @save="handleAgentKnowledgeSave"
      />
      <!--
        Agent System Prompt dialog (Migration 080) — one dialog serves
        add (row=null) and edit (row set). Same show/busy/error pattern
        as the knowledge dialogs above.
      -->
      <AgentSystemPromptDialog
        v-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'agent'"
        :show="agentSystemPromptDialogOpen"
        :row="agentSystemPromptRow"
        :busy="agentSystemPromptBusy"
        :error="agentSystemPromptError"
        @close="closeAgentSystemPromptDialog"
        @create="handleAgentSystemPromptCreate"
        @save="handleAgentSystemPromptSave"
      />
      <AppStandardTaskChatBranch
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type !== 'kanban' &&
          activeWorkspaceItem.item_type !== 'design' &&
          activeWorkspaceItem.item_type !== 'agent' &&
          activeTask
        "
        :task="activeTask"
        :cwd="effectiveChatCwd"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <AppStandaloneChatBranch
        v-else-if="activeChatId.startsWith('chat-')"
        :key="activeChatId"
        :chat-id="activeChatId"
        :chat-name="activeChatName"
        :cwd="effectiveChatCwd"
        @update-chat-id="handleUpdateChatId"
        @close="handleCloseTaskView"
      />
      <Chats v-else-if="currentView === 'chat'" />
      <AppWorkspacePreview v-if="currentView === 'workspace' && !activeWorkspaceItem" />
    </main>
    </div>

    <AppLayoutChrome
      :workspaces="workspacesStore.workspaces"
      :active-workspace-id="activeWorkspaceId"
      :cwd="rightSidebarCwd"
      :view="currentView"
    />

    <!-- Kanban column editor: add / rename / delete a column on the
         currently-active kanban item. Mounted at the AppLayout root
         (not inside the KanbanView's scoped tree) so the modal's
         internal Teleport/animation lifecycle works cleanly even if
         the KanbanView branch unmounts mid-edit (e.g. the user
         clicks a task card and the view switches to ChatView while
         the modal is open). The modal's `show` prop is bound to
         showKanbanColumnEditor; mode/targetId/initialName are set
         by the request-add-column / request-rename-column /
         request-delete-column handlers. -->
    <KanbanColumnEditor
      :show="showKanbanColumnEditor" :mode="kanbanColumnEditorMode"
      :initial-name="kanbanColumnEditorInitialName"
      :initial-description="kanbanColumnEditorInitialDescription"
      :initial-is-done="kanbanColumnEditorInitialIsDone"
      @close="handleKanbanColumnEditorClose" @add="handleKanbanColumnEditorAdd"
      @rename="handleKanbanColumnEditorRename" @delete="handleKanbanColumnEditorDelete"
    />

    <!--
      CopyKanbanSpecDialog — source picker + Replace/Append radio for
      bulk-copying column spec from another kanban. Mounted as a SIBLING
      of <KanbanSettingsView> (not nested) so a user can stack them:
      Settings page under, picker over, both visible at once. The picker
      filters out the active kanban as a source (CopyKanbanSpecDialog's
      `availableSources` computed).
        (Chunk 4, Task 4.3)
    -->
    <CopyKanbanSpecDialog
      :show="showCopyKanbanSpecDialog" :workspace-id="activeWorkspace?.id ?? ''"
      :target-item-id="activeWorkspaceItem?.id ?? ''"
      @close="handleCloseCopyKanbanSpec" @copy="handleCopyKanbanSpec"
    />

    <!-- Move-gate confirm (kanban task dependencies). Offered when
         the backend refuses a column move with 409 + blockers. -->
    <ConfirmDialog
      :show="showMoveBlockedConfirm" title="Task is blocked" :message="moveBlockedMessage"
      confirm-text="Move anyway" @close="handleMoveBlockedClose"
      @confirm="handleMoveBlockedConfirm"
    />
  </div>
</template>

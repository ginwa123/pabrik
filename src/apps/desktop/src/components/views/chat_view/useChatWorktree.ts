import { ref, type Ref } from 'vue'
import * as api from '../../../api'
import { useWorkspacesStore } from '../../../stores/workspaces'

export interface ChatWorktreeDeps {
  sessionId: Ref<string>
  sessionCwd: Ref<string>
  gitWorktreeCwd: Ref<string>
  selectedAgent: Ref<string | null>
  workspacesStore: ReturnType<typeof useWorkspacesStore>
  checkGitStatus: () => Promise<void>
}

export function useChatWorktree(deps: ChatWorktreeDeps) {
  const { sessionId, sessionCwd, gitWorktreeCwd, selectedAgent, workspacesStore, checkGitStatus } =
    deps

  // ─── Worktree dropdown + PR dialog ──────────────────────────────────────────── The chat status
  // bar's git branch indicator becomes a clickable button when a worktree is bound (`gitWorktreeCwd`
  // is non-empty).
  const showWorktreeMenu = ref(false)
  const worktreeMenuRef = ref<HTMLElement | null>(null)
  const showCreatePrDialog = ref(false)
  const showCreateWorktreeDialog = ref(false)

  const onWorktreeMenuCreatePr = () => {
    showCreatePrDialog.value = true
  }

  const onWorktreeMenuCreateWorktree = () => {
    showCreateWorktreeDialog.value = true
  }

  const onWorktreeMenuViewFolder = () => {
    // Open the worktree path (or session cwd if no worktree) in the system file manager.
    // Implementation: use the existing /api/system/folder?path=<worktree> to confirm the directory is
    // accessible, then emit a window event that the right-sidebar file explorer subscribes to.
    const path = gitWorktreeCwd.value || sessionCwd.value
    navigator.clipboard.writeText(path)
    // TODO: open a folder-explorer modal in a follow-up
  }

  const onWorktreeMenuRefresh = () => {
    // Re-fetch git status from the backend so the chip shows the latest
    // state immediately (instead of waiting for the next poll tick).
    checkGitStatus()
  }

  const onWorktreeMenuClear = async () => {
    // Send a system message to the LLM asking it to clear the worktree. The LLM calls
    // set_git_worktree(clear=true), which removes the directory and clears the binding. The SSE event
    // updates the UI.
    if (!sessionId.value) return
    try {
      await api.sendChatMessage(
        sessionId.value,
        'Please call set_git_worktree with clear=true to remove the current worktree binding.',
        sessionCwd.value,
        [],
        selectedAgent.value ?? undefined,
        '',
        [],
        workspacesStore.activeWorkspace?.id,
      )
    } catch (err) {
      console.error('Failed to send clear-worktree message:', err)
    }
  }

  const onPrCreated = (url: string) => {
    showCreatePrDialog.value = false
    // Show a brief toast (use the existing notification pattern)
    // For v1, just open the PR URL in a new tab
    window.open(url, '_blank')
  }

  const onPrError = (message: string) => {
    console.error('PR creation failed:', message)
    // Show a toast with the error
    // For v1, just log — the dialog stays open with the form intact
  }

  const onCreateWorktree = async (path: string) => {
    if (!sessionId.value) return
    if (!sessionCwd.value) {
      console.error('Create worktree: no session cwd available')
      showCreateWorktreeDialog.value = false
      return
    }
    // The dialog passes the user's absolute path verbatim. The LLM calls
    // set_git_worktree(path=<path>) which validates (must be absolute, no .., basename matches
    // [A-Za-z0-9._-]{1,100}) and runs git worktree add.
    const message = `Please call set_git_worktree with path=${path} to create a new worktree for me.`
    try {
      await api.sendChatMessage(
        sessionId.value,
        message,
        sessionCwd.value,
        [],
        selectedAgent.value ?? undefined,
        '',
        [],
        workspacesStore.activeWorkspace?.id,
      )
    } catch (err) {
      console.error('Failed to send create-worktree message:', err)
    }
    showCreateWorktreeDialog.value = false
  }

  return {
    onCreateWorktree,
    onPrCreated,
    onPrError,
    onWorktreeMenuClear,
    onWorktreeMenuCreatePr,
    onWorktreeMenuCreateWorktree,
    onWorktreeMenuRefresh,
    onWorktreeMenuViewFolder,
    showCreatePrDialog,
    showCreateWorktreeDialog,
    showWorktreeMenu,
    worktreeMenuRef,
  }
}

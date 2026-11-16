/** Create-task plumbing for the board: the dialog payload contract, the File → data-URL staging and the single addKanbanTask + moveTaskToColumn call pair. */
import type { useWorkspacesStore } from '../../stores/workspaces'
import type { PreviewFile } from '../file/FilePreview.vue'
import { buildTaskCreateMessage } from './buildTaskCreateMessage'

export interface CreateTaskPayload {
  mode: 'create' | 'create_session' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  // Create-mode worktree toggle from the dialog (undefined = off).
  useGitWorktree?: boolean
  // Create-mode worktree path from the dialog (undefined/empty = agent picks the path itself).
  worktreePath?: string
  // Create-mode base ref the worktree branches FROM, e.g. `origin/main` (undefined/empty = no `Base:` line, so the agent branches from the repo HEAD).
  worktreeBaseBranch?: string
  // Create-mode auto-merge flag from the dialog (undefined = off).
  autoMerge?: boolean
  // The `Method:` line under that note: merge | squash | rebase.
  autoMergeMethod?: string
  tags?: string[]
  // NEW (plan: 2026-08-06-kanban-task-profile-selector).
  selectedAgent?: string
  // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces 2026-08-06-kanban-no-base64-in-desc).
  pendingFiles?: PreviewFile[]
  // NEW (Migration 112 — kanban multi-skill task create).
  skillNames?: string[]
  cwdSession?: string
}

export const fileToBase64 = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = reject
    reader.readAsDataURL(file)
  })

export interface SubmitKanbanTaskArgs {
  store: ReturnType<typeof useWorkspacesStore>
  wsId: string
  itId: string
  desiredColumnId: string
  payload: CreateTaskPayload
  uploadedImageUrls: string[]
}

/** Create the task and move it into the clicked column. */
export const submitKanbanTask = async ({
  store,
  wsId,
  itId,
  desiredColumnId,
  payload,
  uploadedImageUrls,
}: SubmitKanbanTaskArgs): Promise<boolean> => {
  // NEW (plan: 2026-08-14-kanban-task-create-endpoints).
  const queueMessage =
    payload.mode === 'create_and_run'
      ? buildTaskCreateMessage(
          payload.name,
          payload.description,
          payload.useGitWorktree ?? false,
          payload.worktreePath ?? '',
          payload.worktreeBaseBranch ?? '',
          payload.autoMerge ?? false,
          payload.autoMergeMethod ?? '',
        )
      : undefined

  const response = await store.addKanbanTask(wsId, itId, payload.mode, {
    name: payload.name,
    description: payload.description,
    tags: payload.tags,
    cwd: payload.cwdSession,
    isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
    selected_profile_model: payload.selectedAgent,
    skillNames: payload.skillNames ?? [],
    queue_message: queueMessage,
    imageUrls: uploadedImageUrls,
  })

  if (!response.task) {
    // Partial success (create_and_run only) — the store action already surfaced a toast.
    return false
  }

  const taskId = response.task.id

  // Move the task to the column the user clicked.
  await store.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

  // In plain create mode the backend's INSERT path already persisted image_urls (via the createStandardTask useCase).
  return true
}

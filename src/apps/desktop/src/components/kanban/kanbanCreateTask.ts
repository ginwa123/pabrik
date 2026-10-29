/** Create-task plumbing for the board: the dialog payload contract, the File → data-URL staging and
 * the single addKanbanTask + moveTaskToColumn call pair. No try/catch — the caller keeps its guard
 * so the error channel stays in one place. */
import type { useWorkspacesStore } from '../../stores/workspaces'
import type { PreviewFile } from '../file/FilePreview.vue'
import { buildTaskCreateMessage } from './buildTaskCreateMessage'

export interface CreateTaskPayload {
  mode: 'create' | 'create_session' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  // Create-mode worktree toggle from the dialog (undefined = off).
  // Only consumed on the create_and_run path.
  useGitWorktree?: boolean
  // Create-mode worktree path from the dialog (undefined/empty =
  // agent picks the path itself). Only consumed on create_and_run.
  worktreePath?: string
  // Create-mode base ref the worktree branches FROM, e.g. `origin/main`
  // (undefined/empty = no `Base:` line, so the agent branches from the
  // repo HEAD). Only consumed on create_and_run.
  worktreeBaseBranch?: string
  tags?: string[]
  // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty string = backend default / "Default
  // (top-level config)". Threaded through to runAgentOnNewTask only (Path A — plain create doesn't
  // persist the choice; user can set from chatview later).
  selectedAgent?: string
  // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
  // 2026-08-06-kanban-no-base64-in-desc). Files the dialog staged in create mode
  // (KanbanDescriptionEditor.pendingFiles).
  pendingFiles?: PreviewFile[]
  // NEW (Migration 112 — kanban multi-skill task create). The skills the
  // dialog picked, in pick order. Empty array = no skill.
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

/** Create the task and move it into the clicked column. `false` means "the store reported no task"
 * — the caller surfaces that as a retryable error and keeps the dialog open. */
export const submitKanbanTask = async ({
  store,
  wsId,
  itId,
  desiredColumnId,
  payload,
  uploadedImageUrls,
}: SubmitKanbanTaskArgs): Promise<boolean> => {
  // NEW (plan: 2026-08-14-kanban-task-create-endpoints). The 2-step addTask + (in create_and_run)
  // runAgentOnNewTask dance is now a single call to addKanbanTask(mode, payload).
  const queueMessage =
    payload.mode === 'create_and_run'
      ? buildTaskCreateMessage(
          payload.name,
          payload.description,
          payload.useGitWorktree ?? false,
          payload.worktreePath ?? '',
          payload.worktreeBaseBranch ?? '',
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
    // Partial success (create_and_run only) — the store action
    // already surfaced a toast. Keep the dialog open so the user
    // can retry without re-typing.
    return false
  }

  const taskId = response.task.id

  // Move the task to the column the user clicked. The backend's
  // auto-assign put it in the first column; moveTaskToColumn
  // overwrites that. Position 0 = top of the column.
  await store.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

  // In plain create mode the backend's INSERT path already persisted image_urls (via the
  // createStandardTask useCase). In create_and_run mode the same path applies. We don't need a
  // follow-up updateTaskDetails call — the columns are populated server-side now.
  return true
}

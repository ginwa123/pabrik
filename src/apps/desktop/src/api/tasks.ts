import { ApiError, apiFetch } from './client'

export interface Task {
  id: string
  name: string
  description?: string
  // Task type. Optional for backwards compat with legacy task
  // literals. ('routine' was deleted in Migration 084 — routines are
  // now first-class workspace items, see WorkspaceRoutine below.)
  task_type?: 'standard' | 'memory'
  completed?: boolean
  createdAt?: Date
  // ISO datetime string from the backend; present for tasks returned by
  // getTasks() and used to sort/filter on the frontend. Backend stamps this
  // on every update (rename, complete, etc.).
  updatedAt?: Date
  // NEW (pinned-tasks feature). Both optional so legacy task literals in
  // tests keep type-checking.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for tasks under `item_type === 'kanban'`
  // parents. `kanban_column_id` is `null` (not undefined) when the task is unassigned (e.g. its
  // column was deleted). Both optional so legacy task literals keep type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (kanban task tags, Migration 067). Array of free-form tag strings. Empty array = no tags.
  // Optional so legacy task literals in tests keep type-checking. On the wire the field is a
  // JSON-encoded array string; the store normalizes via `normalizeTaskTags` at every fetch site.
  tags?: string[]
  // NEW (kanban image urls, Migration 069). Array of base64 data URLs;
  // empty array = no images. Optional so legacy task literals in tests
  // keep type-checking. On the wire it is a `||`-delimited string.
  imageUrls?: string[]
  // NEW (kanban video urls, Migration 090). Array of base64 data
  // URLs (`data:video/<mime>;base64,<payload>`). Empty array = no
  // videos. Same `||`-delimited wire convention as imageUrls.
  videoUrls?: string[]
  // NEW (Media-flags change — lightweight list/get payload). The backend list/get return only these
  // flags; the full base64 TEXT stays server-side for the lazy `getTaskMedia` endpoint below. The
  // frontend fetches media only when the flag is true.
  is_have_image?: boolean
  is_have_video?: boolean
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override (absolute path,
  // or '' for cwd-less). Optional so legacy task literals in tests keep type-checking. Threaded
  // into the 3-level cwd fallback chain: per-task cwd → kanban-level path → sandbox.
  cwd?: string
  // NEW (kanban task git-branch badge). The current git branch for the task's
  // cwd — worktree cwd if bound, else the parent item's `path`. `null` when the
  // cwd is not a git repo or HEAD is detached; the UI omits the badge.
  git_branch?: string | null
  // NEW (kanban task dependencies). `depends_on` lists ids this task waits for; `blocked_by` is
  // the incomplete subset (names for tooltips); `is_blocked` mirrors `blocked_by.length > 0`.
  depends_on?: string[]
  blocked_by?: TaskDependencyBlocker[]
  is_blocked?: boolean
}

/**
 * One incomplete dependency blocking a task's move — the 409 `blockers` entries.
 */
export interface TaskDependencyBlocker {
  task_id: string
  name: string
  column_id: string | null
  column_name: string | null
}

/**
 * Normalize `depends_on` in place; a malformed wire value becomes `[]` instead of throwing.
 */
export function normalizeTaskDependsOn<T extends { depends_on?: unknown }>(task: T): void {
  const v: unknown = task.depends_on
  if (v === undefined) return
  if (Array.isArray(v)) {
    task.depends_on = v.filter((e): e is string => typeof e === 'string')
    return
  }
  if (typeof v === 'string') {
    try {
      const parsed: unknown = JSON.parse(v)
      task.depends_on = Array.isArray(parsed)
        ? parsed.filter((e): e is string => typeof e === 'string')
        : []
    }
    // eslint-disable-next-line local/no-try-catch -- defensive wire coercion: JSON.parse has no Effect-TS spelling here, and the fallback below documents the failure mode
    catch {
      // Unparseable wire string means "no readable edges" — [] keeps
      // the card rendering (unblocked) instead of crashing on it.
      console.warn('[api] ignoring malformed depends_on wire value')
      task.depends_on = []
    }
    return
  }
  task.depends_on = []
}

/**
 * Read the 409 move-gate `blockers` off a thrown error, or null when it is another failure.
 */
export function parseMoveBlockers(err: unknown): TaskDependencyBlocker[] | null {
  if (!(err instanceof ApiError) || err.status !== 409) return null
  try {
    const parsed: unknown = JSON.parse(err.body)
    if (
      parsed &&
      typeof parsed === 'object' &&
      Array.isArray((parsed as { blockers?: unknown }).blockers)
    ) {
      return (parsed as { blockers: TaskDependencyBlocker[] }).blockers
    }
    return null
  }
  // eslint-disable-next-line local/no-try-catch -- defensive body probe: a non-JSON 409 body simply is not the move-gate shape, and null below documents that
  catch {
    // Non-JSON body cannot carry `blockers` — null tells the
    // caller this error is not a move-gate refusal.
    console.warn('[api] move-gate probe hit a non-JSON 409 body')
    return null
  }
}

/**  * Split a mixed array of base64 data URLs into images vs videos (Migration 090). `data:video/...`
 * entries ride `video_urls`, everything else rides `image_urls`; explicit `videoUrls` args are
 * merged in. */
export function splitMediaUrls(
  urls?: string[],
  extraVideos?: string[],
): {
  images: string[]
  videos: string[]
} {
  const images: string[] = []
  const videos: string[] = [...(extraVideos ?? [])]
  for (const u of urls ?? []) {
    if (u.startsWith('data:video/')) videos.push(u)
    else images.push(u)
  }
  return { images, videos }
}

// Task API
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 10,
  cursor?: string,
  // NEW (2026-08-06): NO default values. Pass `undefined` for both when no sort is in play and let
  // the backend's default (`updated_at desc`) handle it — same wire result, cleaner URL, less
  // coupling.
  sortBy?: 'created_at' | 'updated_at' | 'name',
  direction?: 'asc' | 'desc',
  columnId?: string,
  q?: string,
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  if (sortBy && direction) {
    params.set('sort_by', sortBy)
    params.set('direction', direction)
  }
  if (cursor) {
    params.set('cursor', cursor)
  }
  if (columnId && columnId.length > 0) {
    params.set('column_id', columnId)
  }
  if (q && q.length > 0) {
    params.set('q', q)
  }
  const data = await apiFetch<{
    tasks: Task[]
    has_more: boolean
    next_cursor: string | null
  }>(`/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`)
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}

/** Fetch ONE workspace item task by id (kanban Task details dialog). GET
 * /api/workspaces/:ws/items/:item/tasks/:task_id → { task } | 404. Resolves to the Task, or
 * null on 404 — "the task is gone" is expected, so 404 is silent. Other failures throw. */
export async function getTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<Task | null> {
  try {
    const data = await apiFetch<{ task: Task | null }>(
      `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}`,
      { silent: true },
    )
    return data.task ?? null
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

/** Stamp `workspace_item_tasks.last_human_touched_at` so the kanban card flips from the
 * orange "AI finished — awaiting review" dot to the green "reviewed" checkmark.
 * Fire-and-forget: failures log a warning but don't surface as toasts. */
export async function getTaskMedia(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<TaskMedia | null> {
  try {
    const data = await apiFetch<{ image_urls?: string; video_urls?: string }>(
      `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/tasks/${encodeURIComponent(taskId)}/media`,
      { silent: true },
    )
    const split = (v?: string): string[] => (!v ? [] : v.split('|').filter((seg) => seg.length > 0))
    return { imageUrls: split(data.image_urls), videoUrls: split(data.video_urls) }
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) return null
    throw err
  }
}

export type TaskMedia = { imageUrls: string[]; videoUrls: string[] }

/** Parallel media fetch for MANY tasks (media-flags change). Fires one `getTaskMedia` per
 * id concurrently and settles every leg (`Promise.allSettled`): a single 404 / network blip
 * resolves that entry to null instead of rejecting the whole batch. */
export async function getTasksMedia(
  workspaceId: string,
  itemId: string,
  taskIds: string[],
): Promise<Map<string, TaskMedia | null>> {
  const settled = await Promise.allSettled(
    taskIds.map(
      async (taskId): Promise<[string, TaskMedia | null]> => [
        taskId,
        await getTaskMedia(workspaceId, itemId, taskId),
      ],
    ),
  )
  const out = new Map<string, TaskMedia | null>()
  settled.forEach((entry, i) => {
    if (entry.status === 'fulfilled') out.set(entry.value[0], entry.value[1])
    // Rejected legs (non-404 throw inside getTaskMedia is already
    // narrowed to 404→null, so this is defensive): record null so the
    // caller sees every requested id exactly once.
    else out.set(taskIds[i] ?? '', null)
  })
  return out
}

export async function markTaskHumanTouched(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/touched`,
    { method: 'PUT' },
  )
}

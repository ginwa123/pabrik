import type { Ref } from 'vue'
import * as api from '../../api'
import { readTaskMediaCache, writeTaskMediaCache } from '../../helpers/taskMediaCache'
import type { Task, Workspace, WorkspaceItem } from './types'

interface MediaParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
  cacheTaskMutation: (
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ) => Promise<void>
}

export function createMediaActions(p: MediaParams) {
  const { workspaces, findItem, cacheTaskMutation } = p

  // In-flight media requests, keyed by task id. Concurrent callers
  // (dialog re-open, batch prefetch racing a dialog open) share one
  // promise instead of firing duplicate GETs for the same task.
  const mediaInflight = new Map<string, Promise<void>>()

  function findCachedTask(workspaceId: string, itemId: string, taskId: string): Task | undefined {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return undefined
    return item.tasks.find((t) => t.id === taskId)
  }

  function taskNeedsMedia(task: Task): boolean {
    const wantImage =
      task.is_have_image === true && (!task.imageUrls || task.imageUrls.length === 0)
    const wantVideo =
      task.is_have_video === true && (!task.videoUrls || task.videoUrls.length === 0)
    return wantImage || wantVideo
  }

  // Card-first async media. The flag-only list payload lets cards render immediately (badge state);
  // this queues the thumbnail fetch behind it via GET .../tasks/:id/media.
  function queueCardMediaLoad(workspaceId: string, itemId: string): void {
    const item = findItem(workspaceId, itemId)
    if (!item?.tasks || item.tasks.length === 0) return
    const ids = item.tasks.filter(taskNeedsMedia).map((t) => t.id)
    if (ids.length === 0) return
    let painted = false
    for (const id of ids) {
      const task = findCachedTask(workspaceId, itemId, id)
      if (task) painted = applyCachedMedia(task) || painted
    }
    void fetchTasksMedia(workspaceId, itemId, ids, painted ? { revalidate: true } : undefined)
  }

  // Paints a task's last-known thumbnail from the local media cache.
  // Returns true when anything was painted — the caller then revalidates
  // that task in the background instead of treating it as loaded.
  function applyCachedMedia(task: Task): boolean {
    if (!taskNeedsMedia(task)) return false
    const hit = readTaskMediaCache(task.id)
    if (!hit) return false
    let painted = false
    if (
      task.is_have_image === true &&
      (!task.imageUrls || task.imageUrls.length === 0) &&
      hit.imageUrls.length > 0
    ) {
      task.imageUrls = hit.imageUrls
      painted = true
    }
    if (
      task.is_have_video === true &&
      (!task.videoUrls || task.videoUrls.length === 0) &&
      hit.videoUrls.length > 0
    ) {
      task.videoUrls = hit.videoUrls
      painted = true
    }
    return painted
  }

  // Lazy media fetch (media-flags change). When list/get report `is_have_image` / `is_have_video`,
  // the detail dialog calls this once to populate the cached task's imageUrls/videoUrls in place
  // (shared with the board card thumbnail).
  async function fetchTaskMedia(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<void> {
    const task = findCachedTask(workspaceId, itemId, taskId)
    if (!task) return
    const painted = applyCachedMedia(task)
    if (!taskNeedsMedia(task) && !painted) return
    const inflight = mediaInflight.get(taskId)
    if (inflight) {
      await inflight
      return
    }
    const run = (async (): Promise<void> => {
      try {
        const current = findCachedTask(workspaceId, itemId, taskId)
        if (!current || (!taskNeedsMedia(current) && !painted)) return
        const media = await api.getTaskMedia(workspaceId, itemId, taskId)
        if (!media) return
        writeTaskMediaCache(taskId, media)
        const fresh = findCachedTask(workspaceId, itemId, taskId)
        if (!fresh) return
        if (
          fresh.is_have_image === true &&
          (!fresh.imageUrls || fresh.imageUrls.length === 0 || painted)
        )
          fresh.imageUrls = media.imageUrls
        if (
          fresh.is_have_video === true &&
          (!fresh.videoUrls || fresh.videoUrls.length === 0 || painted)
        )
          fresh.videoUrls = media.videoUrls
        await cacheTaskMutation(workspaceId, itemId, fresh, fresh.kanban_column_id ?? undefined)
      } catch (err) {
        console.warn('Failed to fetch task media:', err)
      } finally {
        mediaInflight.delete(taskId)
      }
    })()
    mediaInflight.set(taskId, run)
    await run
  }

  // Parallel batch prefetch (media-flags change). Fetches media for every flagged-but-unloaded task
  // concurrently via one `api.getTasksMedia` round (≈ one round-trip, not N sequential).
  async function fetchTasksMedia(
    workspaceId: string,
    itemId: string,
    taskIds: string[],
    opts?: { revalidate?: boolean },
  ): Promise<void> {
    const revalidate = opts?.revalidate === true
    const pending = taskIds.filter((id) => {
      const task = findCachedTask(workspaceId, itemId, id)
      return task !== undefined && (taskNeedsMedia(task) || revalidate) && !mediaInflight.has(id)
    })
    const alreadyRunning = taskIds
      .map((id) => mediaInflight.get(id))
      .filter((p): p is Promise<void> => p !== undefined)
    if (pending.length === 0) {
      await Promise.allSettled(alreadyRunning)
      return
    }
    // Note: the `finally` below deletes map entries unconditionally. Safe: a new request for the
    // same id can only start when the map holds no entry, and entries are removed only here — no
    // caller can replace an in-flight entry mid-run (single-threaded).
    const run = (async (): Promise<void> => {
      try {
        const results = await api.getTasksMedia(workspaceId, itemId, pending)
        for (const [id, media] of results) {
          if (!media) continue
          writeTaskMediaCache(id, media)
          const task = findCachedTask(workspaceId, itemId, id)
          if (!task) continue
          if (
            task.is_have_image === true &&
            (!task.imageUrls || task.imageUrls.length === 0 || revalidate)
          )
            task.imageUrls = media.imageUrls
          if (
            task.is_have_video === true &&
            (!task.videoUrls || task.videoUrls.length === 0 || revalidate)
          )
            task.videoUrls = media.videoUrls
          await cacheTaskMutation(workspaceId, itemId, task, task.kanban_column_id ?? undefined)
        }
      } catch (err) {
        console.warn('Failed to fetch tasks media:', err)
      } finally {
        for (const id of pending) mediaInflight.delete(id)
      }
    })()
    for (const id of pending) mediaInflight.set(id, run)
    await run
    await Promise.allSettled(alreadyRunning)
  }

  return {
    findCachedTask,
    fetchTaskMedia,
    fetchTasksMedia,
    queueCardMediaLoad,
  }
}

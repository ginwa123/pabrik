import { normalizeTaskDependsOn } from '../../api'
import type { Task } from './types'

// Kanban task tags normalization (Migration 067).
export function normalizeTaskTags(task: Task): Task {
  // Kanban task dependencies ride the same fetch sites: coerce
  // `depends_on` to string[] (wire is a real array; tolerated
  // as a JSON string defensively, absent stays absent).
  normalizeTaskDependsOn(task)
  if (task.tags === undefined) {
    // Still normalize imageUrls + dates even when tags is missing
    // (the fields are independent — a task can have tags but no
    // images or vice versa).
    normalizeTaskImageUrlsInPlace(task)
    normalizeTaskVideoUrlsInPlace(task)
    normalizeTaskDatesInPlace(task)
    return task
  }
  // Coerce anything (string, already-array, missing) to a string[]. Defensive: legacy rows from
  // before Migration 067 might have undefined OR an empty string.
  if (typeof task.tags === 'string') {
    try {
      const parsed = JSON.parse(task.tags) as unknown
      task.tags = Array.isArray(parsed) ? (parsed as string[]) : []
    } catch {
      task.tags = []
    }
  } else if (!Array.isArray(task.tags)) {
    task.tags = []
  }
  normalizeTaskImageUrlsInPlace(task)
  normalizeTaskVideoUrlsInPlace(task)
  normalizeTaskDatesInPlace(task)
  return task
}

// Parse the backend's wire-format datetime string into a Date. Backend format: `"YYYY-MM-DD
// HH:MM:SS"` (UTC, from SQLite DATETIME columns) OR an ISO 8601 string (`"YYYY-MM-DDTHH:MM:SSZ"` /
// with offset).
function parseBackendDatetime(value: unknown): Date | undefined {
  if (typeof value !== 'string' || value.length === 0) return undefined
  // Normalise "YYYY-MM-DD HH:MM:SS" → "YYYY-MM-DDTHH:MM:SS" so the Date ctor parses it. Then inject
  // an explicit `Z` (UTC) when the string has no timezone marker — the backend stores UTC strings
  // without an explicit zone.
  const isoish = value.includes('T') ? value : value.replace(' ', 'T')
  const hasZone = isoish.endsWith('Z') || /[+-]\d{2}:?\d{2}$/.test(isoish)
  const d = new Date(hasZone ? isoish : isoish + 'Z')
  return Number.isNaN(d.getTime()) ? undefined : d
}

// Wire→in-memory date normalization for tasks. The backend returns `created_at` and `updated_at` as
// snake_case UTC strings (`"2026-08-05 04:24:56"`). The `Task` interface declares `createdAt?:
// Date` and `updatedAt?: Date` (camelCase, Date object).
function normalizeTaskDatesInPlace(task: Task): void {
  // The wire fields aren't declared on the local `Task` interface (only the camelCase Date variants
  // are), so we cast through `unknown` to access them. This is the same pattern used by the
  // existing tags + imageUrls normalizers in this file.
  const wire = task as unknown as Record<string, unknown>
  if (task.updatedAt === undefined) {
    const parsed = parseBackendDatetime(wire['updated_at'])
    if (parsed !== undefined) task.updatedAt = parsed
  }
  if (task.createdAt === undefined) {
    const parsed = parseBackendDatetime(wire['created_at'])
    if (parsed !== undefined) task.createdAt = parsed
  }
}

// Decode the `||`-delimited `image_urls` wire string into a `string[]` (Migration 069 — kanban
// image urls column).
function normalizeTaskImageUrlsInPlace(task: Task): void {
  // Wire→camel bridge (read-path fix, 2026-08-24): the backend's WorkspaceItemTaskResponse
  // serializes the field as snake_case `image_urls` (the ||-delimited string), but the Task
  // interface + every consumer read camelCase `imageUrls`.
  if (task.imageUrls === undefined) {
    const wire = task as unknown as Record<string, unknown>
    const wireVal = wire['image_urls']
    if (wireVal === undefined) return
    // Present the wire value to the splitter below via the camelCase
    // field (string | string[] | anything-else all handled there).
    task.imageUrls = wireVal as string[]
  }
  // Already an array (legacy code paths / optimistic local writes).
  if (Array.isArray(task.imageUrls)) return
  // Wire format: `||`-delimited base64 data URLs. '' → [] (no images) 'data:...' → ['data:...']
  // (one image) 'a||b||c' → ['a', 'b', 'c'] (multiple images) Filter empty segments so
  // trailing/consecutive `||` don't leak through as empty entries.
  if (typeof task.imageUrls === 'string') {
    const joined = task.imageUrls as string
    if (joined === '') {
      task.imageUrls = []
    } else {
      task.imageUrls = joined.split('|').filter((s) => s.length > 0)
    }
  } else {
    task.imageUrls = []
  }
}

// Decode the `||`-delimited `video_urls` wire string into a `string[]`
// (Migration 090 — kanban video urls column). Same wire→camel bridge
// + splitter contract as normalizeTaskImageUrlsInPlace above.
function normalizeTaskVideoUrlsInPlace(task: Task): void {
  if (task.videoUrls === undefined) {
    const wire = task as unknown as Record<string, unknown>
    const wireVal = wire['video_urls']
    if (wireVal === undefined) return
    task.videoUrls = wireVal as string[]
  }
  if (Array.isArray(task.videoUrls)) return
  if (typeof task.videoUrls === 'string') {
    const joined = task.videoUrls as string
    if (joined === '') {
      task.videoUrls = []
    } else {
      task.videoUrls = joined.split('|').filter((s) => s.length > 0)
    }
  } else {
    task.videoUrls = []
  }
}

// Decode the `||`-delimited `image_urls` wire string into a `string[]` (REMOVED — folded into
// normalizeTaskTags above.

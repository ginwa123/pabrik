/** Shared FOLDER-mode diff snapshot — the app's only way to read a file diff. Why this exists */
import { getGitFolderDiffs, type GitFileDiff } from '../api'

/** Matches the sidebar's git-status poll. See note above. */
export const FOLDER_DIFF_TTL_MS = 30_000

/** Repos remembered at once. */
const MAX_TRACKED_CWDS = 8

type Snapshot = { at: number; byKey: Map<string, GitFileDiff> }

const snapshots = new Map<string, Snapshot>()
const inflight = new Map<string, Promise<Map<string, GitFileDiff>>>()

/** `staged` is part of the key: the same path has two independent diffs. */
export function folderDiffKey(staged: boolean, path: string): string {
  return `${staged ? 1 : 0}:${path}`
}

/** Test-only escape hatch — drops every snapshot and in-flight fetch. */
export function clearFolderDiffCache(): void {
  snapshots.clear()
  inflight.clear()
}

function evictOldest(): void {
  // Map preserves insertion order; re-inserting on every prime keeps the most-recently-written cwd last.
  while (snapshots.size > MAX_TRACKED_CWDS) {
    const oldest = snapshots.keys().next()
    if (oldest.done) return
    snapshots.delete(oldest.value)
  }
}

/** Store a whole-repo (or folder) diff payload as the snapshot for `cwd`. */
export function primeFolderDiffs(cwd: string, diffs: GitFileDiff[]): void {
  if (!cwd) return
  const byKey = new Map<string, GitFileDiff>()
  for (const d of diffs) byKey.set(folderDiffKey(d.staged, d.path), d)
  // Delete-then-set so the insertion order reflects "written last", which is what `evictOldest` reads.
  snapshots.delete(cwd)
  snapshots.set(cwd, { at: Date.now(), byKey })
  evictOldest()
}

/** The diff for one file, or null when the snapshot is missing or expired. */
export function readFolderDiff(cwd: string, path: string, staged: boolean): GitFileDiff | null {
  if (!cwd || !path) return null
  const snap = snapshots.get(cwd)
  if (!snap) return null
  if (Date.now() - snap.at >= FOLDER_DIFF_TTL_MS) {
    // Expired.
    snapshots.delete(cwd)
    return null
  }
  return snap.byKey.get(folderDiffKey(staged, path)) ?? null
}

/** True when `cwd` has a snapshot that `readFolderDiff` will still serve. */
export function hasFreshFolderSnapshot(cwd: string): boolean {
  const snap = snapshots.get(cwd)
  return !!snap && Date.now() - snap.at < FOLDER_DIFF_TTL_MS
}

function fetchSnapshot(cwd: string): Promise<Map<string, GitFileDiff>> {
  const ongoing = inflight.get(cwd)
  if (ongoing) return ongoing
  const request = (async () => {
    const res = await getGitFolderDiffs(cwd)
    primeFolderDiffs(cwd, res.diffs)
    const snap = snapshots.get(cwd)
    if (!snap) throw new Error(`folder diff snapshot vanished for ${cwd}`)
    return snap.byKey
  })()
  // Cleanup runs on both paths, and the rejection is handed to every caller (no `.catch` here) — swallowing it would turn a backend outage into an empty diff that …
  const tracked = request.finally(() => {
    inflight.delete(cwd)
  })
  inflight.set(cwd, tracked)
  return tracked
}

/** Diff for one file, from the shared snapshot. */
export async function fetchFolderDiff(
  cwd: string,
  path: string,
  staged: boolean,
): Promise<GitFileDiff> {
  const empty: GitFileDiff = { path, diff_content: '', staged }
  if (!cwd || !path) return empty
  // A FRESH snapshot is authoritative, so a path it does not list means "no diff" — answer from it instead of revalidating.
  if (hasFreshFolderSnapshot(cwd)) return readFolderDiff(cwd, path, staged) ?? empty
  const byKey = await fetchSnapshot(cwd)
  return byKey.get(folderDiffKey(staged, path)) ?? empty
}

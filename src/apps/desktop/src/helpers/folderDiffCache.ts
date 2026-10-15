/**
 * Shared FOLDER-mode diff snapshot — the app's only way to read a file diff.
 *
 * Why this exists: `POST /api/git/file/diffs` in folder mode returns every
 * changed path under a folder (or the whole repo) in ONE request. Before this
 * module, two components still reached for the per-file
 * `GET /api/git/file/diff`, so opening the diff panel fired one request per
 * click and the standalone viewer fired one per file opened. That is the
 * request flood in the browser's network tab.
 *
 * So: ONE snapshot per cwd, shared by every reader.
 *   - `primeFolderDiffs` — the sidebar already fetched the whole repo for its
 *     file list; hand the payload over so a click costs ZERO requests.
 *   - `readFolderDiff` — synchronous read, for a click on a file the snapshot
 *     already covers.
 *   - `fetchFolderDiff` — read, or revalidate with a single shared folder
 *     request (concurrent callers are deduped into the same promise).
 *
 * TTL is 30s on purpose: that is the sidebar's existing poll cadence
 * (`SidebarDiffPanel.loadGitStatus`), so a reader can never drift further
 * behind the panel than the panel already does. The panel re-primes on every
 * poll, which resets the clock for everyone.
 *
 * The frontend and the backend ship together, so there is no "older server"
 * to fall back to — a rejected fetch REJECTS here and the caller renders an
 * error, rather than silently degrading into a per-file request storm.
 */
import { getGitFolderDiffs, type GitFileDiff } from '../api'

/** Matches the sidebar's git-status poll. See note above. */
export const FOLDER_DIFF_TTL_MS = 30_000

/** Repos remembered at once. A session flip-flopping across >8 worktrees
 *  evicts the oldest rather than growing without bound. */
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
  // Map preserves insertion order; re-inserting on every prime keeps the
  // most-recently-written cwd last.
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
  // Delete-then-set so the insertion order reflects "written last", which is
  // what `evictOldest` reads.
  snapshots.delete(cwd)
  snapshots.set(cwd, { at: Date.now(), byKey })
  evictOldest()
}

/** The diff for one file, or null when the snapshot is missing or expired.
 * A file the server did not report is null too — the caller decides whether
 * that means "clean file" (empty diff) or "ask again". */
export function readFolderDiff(cwd: string, path: string, staged: boolean): GitFileDiff | null {
  if (!cwd || !path) return null
  const snap = snapshots.get(cwd)
  if (!snap) return null
  if (Date.now() - snap.at >= FOLDER_DIFF_TTL_MS) {
    // Expired. Drop it so the next read cannot accidentally serve it, and so
    // an abandoned cwd's entry does not linger in the eviction queue.
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
  // Cleanup runs on both paths, and the rejection is handed to every caller
  // (no `.catch` here) — swallowing it would turn a backend outage into an
  // empty diff that reads as "this file is unchanged".
  const tracked = request.finally(() => {
    inflight.delete(cwd)
  })
  inflight.set(cwd, tracked)
  return tracked
}

/**
 * Diff for one file, from the shared snapshot. Revalidates with a single
 * folder request when the snapshot is missing or older than the TTL;
 * concurrent callers share that one request.
 *
 * Resolves to a diff entry even when the path is absent from the payload —
 * the server only reports CHANGED paths, so a missing path means "no diff",
 * which is what the per-file endpoint used to answer with empty content.
 * REJECTS when the fetch itself fails; callers render that as an error.
 */
export async function fetchFolderDiff(
  cwd: string,
  path: string,
  staged: boolean,
): Promise<GitFileDiff> {
  const empty: GitFileDiff = { path, diff_content: '', staged }
  if (!cwd || !path) return empty
  // A FRESH snapshot is authoritative, so a path it does not list means "no diff" — answer from it
  // instead of revalidating. Refetching here would bring back one request per click for every file
  // that happens to be unchanged, which is the flood this module exists to remove.
  if (hasFreshFolderSnapshot(cwd)) return readFolderDiff(cwd, path, staged) ?? empty
  const byKey = await fetchSnapshot(cwd)
  return byKey.get(folderDiffKey(staged, path)) ?? empty
}

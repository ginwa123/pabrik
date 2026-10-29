import { readGitStatusCache, writeGitStatusCache } from '../helpers/gitStatusCache'
import { Cause, Data, Effect } from 'effect'
import { describeCause } from '../helpers/effectRuntime'
import { apiFetch } from './core'

// Git Status API
export interface GitStatus {
  is_git_repo: boolean
  branch: string
  has_changes: boolean
  is_clean: boolean
  current: string
  status: string
}

export interface GitFileChange {
  index_status: string
  worktree_status: string
  path: string
}

export interface GitChangesResponse {
  is_git_repo: boolean
  branch: string | null
  has_changes: boolean
  staged_files: GitFileChange[]
  modified_files: GitFileChange[]
  untracked_files: GitFileChange[]
}

export async function getGitStatus(cwd: string): Promise<GitStatus> {
  try {
    const status = await apiFetch<GitStatus>(`/git/status?path=${encodeURIComponent(cwd)}`)
    writeGitStatusCache(cwd, status)
    return status
  } catch {
    // Stale-while-revalidate: a failed refresh falls back to the last-known status for this cwd so
    // the branch chip keeps showing something real instead of blanking on a transient backend
    // error.
    return (
      readGitStatusCache(cwd) ?? {
        is_git_repo: false,
        branch: '',
        has_changes: false,
        is_clean: true,
        current: '',
        status: 'error',
      }
    )
  }
}

export async function getGitChanges(cwd: string): Promise<GitChangesResponse> {
  try {
    return await apiFetch<GitChangesResponse>(`/git/changes?path=${encodeURIComponent(cwd)}`)
  } catch {
    // Return non-repo status on error (apiFetch also fires a toast
    // notification on non-2xx; the empty status fallback ensures the
    // UI doesn't crash while the user sees the error).
    return {
      is_git_repo: false,
      branch: null,
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    }
  }
}

// Git blame — per-line author + commit time for one file, backing the
// CodeEditor's inline blame annotation.
export interface GitBlameLine {
  line: number
  commit: string
  author: string
  author_time: number
  summary: string
}

export interface GitBlameResponse {
  is_git_repo: boolean
  lines: GitBlameLine[]
}

/** The blame fetch failed — transport or non-2xx. */
export class GitBlameError extends Data.TaggedError('GitBlameError')<{
  readonly cwd: string
  readonly file: string
  readonly reason: string
}> {}

/** The blame endpoint, WITH the failure in the type — no `try`/`catch`
 * (AGENTS.md, "Frontend — No `try`/`catch` in the desktop app"). */
export function fetchGitBlameEffect(
  cwd: string,
  filePath: string,
): Effect.Effect<GitBlameResponse, GitBlameError> {
  return Effect.tryPromise({
    try: () =>
      apiFetch<GitBlameResponse>(
        `/git/blame?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
        { silent: true },
      ),
    catch: (cause) =>
      new GitBlameError({ cwd, file: filePath, reason: describeCause(Cause.fail(cause)) }),
  })
}

/**  * Best-effort blame: a failure yields null (the file paints without chips) on the Effect seam, so
 * no `try`/`catch` sits between the failure and the value. The reason is logged, not discarded. */
export function getGitBlame(cwd: string, filePath: string): Promise<GitBlameResponse | null> {
  return Effect.runPromise(
    fetchGitBlameEffect(cwd, filePath).pipe(
      Effect.catchAll((error) => {
        console.log(error)
        return Effect.succeed(null)
      }),
    ),
  )
}

// Git worktree info — used by the "Create a PR" dialog to pre-fill the form.
export interface GitWorktreeInfo {
  is_git_repo: boolean
  branch: string
  last_commit_sha: string
  last_commit_msg: string
  default_base: string
  commits_ahead: number
  diff_summary: string
  draft_title: string
  draft_body: string
}

export async function getGitWorktreeInfo(
  worktreePath: string,
  base?: string,
): Promise<GitWorktreeInfo> {
  try {
    const params = new URLSearchParams({ path: worktreePath })
    if (base && base.trim() !== '') {
      params.set('base', base)
    }
    return await apiFetch<GitWorktreeInfo>(`/git/worktree/info?${params}`)
  } catch (error) {
    console.error('Failed to get git worktree info:', error)
    return {
      is_git_repo: false,
      branch: '',
      last_commit_sha: '',
      last_commit_msg: '',
      default_base: base || 'main',
      commits_ahead: 0,
      diff_summary: '',
      draft_title: '',
      draft_body: '',
    }
  }
}

// ─── Git branches (kanban worktree base-branch picker) ──────────────────── Wire shape for `GET
// /api/git/branches?path=<repo>`. Feeds the "New task" dialog's base-branch dropdown so a fresh
// worktree can branch from e.g. `origin/main` instead of whatever the repo's current HEAD is.
export interface GitBranchEntry {
  /** Short ref name, e.g. `origin/main` or `main`. This is the exact
   *  string baked into the create-task message's `Base:` line. */
  name: string
  /** True for a remote-tracking ref (`origin/...`). */
  is_remote: boolean
  /** True for the repo's currently checked-out branch (`''` in a bare
   *  repo / detached HEAD — no row is highlighted). */
  is_current: boolean
  /** True for the detected default base (`origin/main` → … ). The
   *  component uses this to preselect a sensible value. */
  is_default: boolean
}

export interface GitBranchesResponse {
  is_git_repo: boolean
  current_branch: string
  branches: GitBranchEntry[]
}

/** List the local + remote-tracking branches of the repo at `repoPath`. */
export async function listGitBranches(repoPath: string): Promise<GitBranchesResponse> {
  const empty: GitBranchesResponse = {
    is_git_repo: false,
    current_branch: '',
    branches: [],
  }
  const path = (repoPath ?? '').trim()
  if (path === '') return empty
  try {
    const params = new URLSearchParams({ path })
    return await apiFetch<GitBranchesResponse>(`/git/branches?${params}`)
  } catch (error) {
    console.error('Failed to list git branches:', error)
    return empty
  }
}

// ─── Git commits (read-only lazygit-style history) ──────────────────────── Wire shape for `GET
// /api/git/commits?path=<repo>[&limit=][&skip=]` and `GET /api/git/commit?path=<repo>&sha=<sha>`.
// Read-only: list + detail, no checkout/amend/rebase.
export interface GitCommit {
  sha: string
  short_sha: string
  author: string
  email: string
  /** Unix timestamp (seconds). */
  timestamp: number
  subject: string
  body: string
}

export interface GitCommitsResponse {
  is_git_repo: boolean
  branch: string
  /** Best-effort `rev-list --count HEAD` (0 when unresolvable). */
  total_count: number
  commits: GitCommit[]
}

export async function getGitCommits(
  cwd: string,
  limit = 100,
  skip = 0,
): Promise<GitCommitsResponse> {
  const empty: GitCommitsResponse = {
    is_git_repo: false,
    branch: '',
    total_count: 0,
    commits: [],
  }
  const path = (cwd ?? '').trim()
  if (path === '') return empty
  try {
    const params = new URLSearchParams({ path })
    params.set('limit', String(limit))
    params.set('skip', String(skip))
    return await apiFetch<GitCommitsResponse>(`/git/commits?${params}`)
  } catch (error) {
    console.error('Failed to list git commits:', error)
    return empty
  }
}

export interface GitCommitFile {
  status: string
  path: string
}

export interface GitCommitDetail extends GitCommit {
  files: GitCommitFile[]
}

export async function getGitCommitDetail(
  cwd: string,
  sha: string,
): Promise<GitCommitDetail | null> {
  const path = (cwd ?? '').trim()
  const ref = (sha ?? '').trim()
  if (path === '' || ref === '') return null
  try {
    const params = new URLSearchParams({ path, sha: ref })
    return await apiFetch<GitCommitDetail>(`/git/commit?${params}`)
  } catch (error) {
    console.error('Failed to load git commit detail:', error)
    return null
  }
}

export interface GitCommitFileDiff {
  sha: string
  path: string
  diff_content: string
}

/**  * Unified diff of one file at one commit (`git diff <sha>^ <sha>`, root-commit fallback via `git
 * show`). Powers the clickable file rows in the commits view. Returns null on any failure so the
 * row can show an inline error instead of crashing. */
export async function getGitCommitFileDiff(
  cwd: string,
  sha: string,
  file: string,
): Promise<GitCommitFileDiff | null> {
  const path = (cwd ?? '').trim()
  const ref = (sha ?? '').trim()
  const target = (file ?? '').trim()
  if (path === '' || ref === '' || target === '') return null
  try {
    const params = new URLSearchParams({ path, sha: ref, file: target })
    return await apiFetch<GitCommitFileDiff>(`/git/commit/file?${params}`)
  } catch (error) {
    console.error('Failed to load git commit file diff:', error)
    return null
  }
}

import { apiFetch } from './client'

// Open a PR/MR in the worktree path via the forge CLI (`gh pr create` or
// `glab mr create`). The backend runs the command and returns the URL.
export interface GitPrCreateResponse {
  success: boolean
  pr_url: string
  // Renamed from `error_message` per PR review (git_pr_create.zig:60). The Zig struct field is
  // `@"error"` (because `error` is a Zig keyword) and serializes to JSON `"error"`. This frontend
  // field name matches the JSON wire format.
  error: string
  // Which forge the PR/MR was opened on. Absent on older servers.
  provider?: string
}

/** Open a PR/MR on `worktreePath`. */
export async function createGitPr(
  worktreePath: string,
  base: string,
  title: string,
  body: string,
  opts?: { provider?: string },
): Promise<GitPrCreateResponse> {
  return await apiFetch<GitPrCreateResponse>('/git/pr', {
    method: 'POST',
    body: {
      worktree_path: worktreePath,
      base,
      title,
      body,
      provider: opts?.provider || '',
    },
  })
}

// PR Diff API — full unified diff for the PR attached to a session
// (set_pull_request tool). Consumed by the ChatView right panel's
// PR mode, which splits per file client-side.
export interface GitPrDiff {
  pr_url: string
  base: string
  head: string
  diff_content: string // Full unified diff output
  truncated: boolean
}

export async function getPrDiff(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string; base?: string; head?: string },
): Promise<GitPrDiff> {
  const params = new URLSearchParams({
    path: cwd,
    pr_url: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  if (opts?.base) params.set('base', opts.base)
  if (opts?.head) params.set('head', opts.head)
  return await apiFetch<GitPrDiff>(`/git/pr/diff?${params.toString()}`)
}

// PR status API — open/merged/closed state for the attached PR
// (GET /api/git/pr/status via `gh pr view`). The PR tab polls this
// so a merge on GitHub flips the badge without a manual refresh.
export interface GitPrStatus {
  // Which forge answered: `github` | `gitlab`. Absent on older servers.
  provider?: string
  pr_url: string
  number: number
  title: string
  state: string
  status: string // open | closed | merged (lowercased by backend)
  mergeable: string
  merge_state: string
  /**    * The commit the head branch points at (`headRefOid` / GitLab `sha`). It is the merge box's head
   * guard: `--match-head-commit` / `--sha`, so a merge cannot land on a commit the user never saw.
   * `''` on older servers. */
  head_sha: string
  head_ref: string
  base_ref: string
  author: string
  created_at: string
  updated_at: string
  merged_at: string
  closed_at: string
  additions: number
  deletions: number
  changed_files: number
  /** APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED, or "" when the forge has no
   *  verdict to give. It is the sentence behind "Merging is blocked". */
  review_decision: string
  /** The CI rollup, counted. The header chips and the merge box read it. */
  checks: GitPrChecksSummary
}

export async function getPrStatus(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrStatus> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  return await apiFetch<GitPrStatus>(`/git/pr/status?${params.toString()}`, { silent: true })
}

// The change request's conversation (GET /api/git/pr/conversation): the body,
// the comments and the review verdicts. Every body here is authored by someone
// who can comment on the repo, so it is rendered through helpers/markdown.ts.
export interface GitPrConversationComment {
  author: string
  body: string
  created_at: string
  url: string
}

export interface GitPrConversationReview {
  author: string
  /** APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED */
  state: string
  body: string
  created_at: string
  url: string
}

export interface GitPrConversation {
  provider: string
  number: number
  title: string
  /** The request's own description, in markdown. */
  body: string
  author: string
  created_at: string
  review_decision: string
  comments: GitPrConversationComment[]
  reviews: GitPrConversationReview[]
  /** Comments plus reviews: how many entries the thread holds. */
  comment_count: number
  /** A non-fatal note about the answer, rendered inline. */
  detail: string
}

export async function getPrConversation(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrConversation> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  // silent: true — the Conversation tab renders the server's own error
  // sentence inline, so a toast would only repeat it.
  return await apiFetch<GitPrConversation>(`/git/pr/conversation?${params.toString()}`, {
    silent: true,
  })
}

// PR/MR list for a repo (GET /api/git/pr/list via `gh pr list` /
// `glab mr list`). Powers the board-level change-request list — one
// call for the whole repo, not one per card.
export interface GitPrListItem {
  number: number
  title: string
  url: string
  state: string
  is_draft: boolean
  head_ref: string
  base_ref: string
  author: string
  updated_at: string
}

export interface GitPrListResponse {
  provider: string
  program: string
  state: string
  truncated: boolean
  detail: string
  changes: GitPrListItem[]
}

export async function listPrs(
  cwd: string,
  opts?: { provider?: string; state?: string; limit?: number },
): Promise<GitPrListResponse> {
  const params = new URLSearchParams({
    path: cwd,
  })
  if (opts?.state) params.set('state', opts.state)
  if (opts?.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts?.provider) params.set('provider', opts.provider)
  // silent: true — the list view renders the forge's own error
  // sentence inline (an error banner, not a toast), and the board
  // button leaves its badge absent on failure.
  return await apiFetch<GitPrListResponse>(`/git/pr/list?${params.toString()}`, { silent: true })
}

// Close a PR/MR (POST /api/git/pr/close). `closed: false` with a `detail` is NOT an error status —
// the forge accepted the command but the re-read still shows it open, so the UI must render the
// forge's sentence rather than claim success.
export interface GitPrCloseResponse {
  closed: boolean
  detail: string
  provider: string
  status: GitPrStatus
}

export async function closePr(
  cwd: string,
  pr: string,
  opts?: { provider?: string },
): Promise<GitPrCloseResponse> {
  // silent: true — the list view renders both the `closed: false`
  // detail and the 502 `{ error }` sentence inline next to the row.
  return await apiFetch<GitPrCloseResponse>('/git/pr/close', {
    method: 'POST',
    silent: true,
    timeoutMs: 90_000,
    body: {
      path: cwd,
      pr,
      provider: opts?.provider || undefined,
    },
  })
}

/** Merge a PR/MR (POST /api/git/pr/merge). `method` is REQUIRED: the backend refuses an empty one
 * with a 400 rather than spawning, because `gh pr merge` without a strategy flag prompts for the
 * method and a non-tty child cannot answer it. */
export interface GitPrMerge {
  success: boolean
  method: string
  pending: boolean
  status: GitPrStatus
}

export interface MergePrOptions {
  provider?: string
  method: 'merge' | 'squash' | 'rebase'
  /** Commit message for the merge/squash commit. */
  title?: string
  body?: string
  /** Delete the source branch after merging. Off by default in the UI: the
   *  source branch is usually the session's own worktree branch. */
  delete_branch?: boolean
  /** The head commit the user was looking at. Both CLIs guard on it. */
  head_sha?: string
}

export async function mergePr(
  cwd: string,
  prUrl: string,
  opts: MergePrOptions,
): Promise<GitPrMerge> {
  // The route spawns a forge CLI against a network, so it is given a far larger budget than the 15
  // s default — the same reason `git_pr_merge.zig` runs the child under a 60 s deadline. `silent`
  // because the box renders the server's own words inline instead of a toast.
  return await apiFetch<GitPrMerge>('/git/pr/merge', {
    method: 'POST',
    silent: true,
    timeoutMs: 90_000,
    body: {
      path: cwd,
      pr: prUrl,
      provider: opts.provider || undefined,
      method: opts.method,
      title: opts.title || undefined,
      body: opts.body || undefined,
      delete_branch: !!opts.delete_branch,
      head_sha: opts.head_sha || undefined,
    },
  })
}

/** PR CI checks (GET /api/git/pr/checks via `gh pr checks`). `checks` is one row per CI job;
 * `steps` is filled in for failed and cancelled jobs only — "which job failed" is already on the PR
 * page, "which process or task failed" is what the user comes here for. */
export interface GitPrCheckStep {
  name: string
  number: number
  conclusion: string // success | failure | cancelled | skipped | neutral | timed_out | ''
  status: string // queued | in_progress | completed
  started_at: string
  completed_at: string
}

export interface GitPrCheck {
  name: string
  workflow: string
  bucket: string // pass | fail | pending | skipping | cancel
  state: string
  link: string
  started_at: string
  completed_at: string
  steps: GitPrCheckStep[]
  steps_error: string
}

export interface GitPrChecksSummary {
  total: number
  passed: number
  failed: number
  pending: number
  skipped: number
  cancelled: number
}

export interface GitPrChecks {
  provider: string
  pr_url: string
  checks: GitPrCheck[]
  summary: GitPrChecksSummary
  /** Some failed jobs have no steps because the run-lookup budget ran out. */
  steps_truncated: boolean
}

export async function getPrChecks(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string },
): Promise<GitPrChecks> {
  const params = new URLSearchParams({
    path: cwd,
    pr: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  // `silent: true`: the Checks tab renders its own error inline, and a
  // toast per poll would be noise on top of it.
  return await apiFetch<GitPrChecks>(`/git/pr/checks?${params.toString()}`, { silent: true })
}

// Which-files-conflict API. `getPrStatus` tells us a PR is CONFLICTING but not what blocks it — no
// forge API exposes that, so the backend runs the same three-way merge locally (`git merge-tree
// --write-tree --name-only`) and names the paths.
export interface GitPrConflicts {
  pr_url: string
  /** The ref the merge was computed against, e.g. `refs/remotes/origin/main`. */
  base_ref: string
  /** Short commit `base_ref` pointed at. '' when rev-parse failed (cosmetic). */
  base_commit: string
  head: string
  /** Paths git refused to merge cleanly. Empty is a legitimate answer. */
  conflicting_files: string[]
  count: number
  /** True when the server capped `conflicting_files`. */
  truncated: boolean
}

export async function getPrConflicts(
  cwd: string,
  prUrl: string,
  opts?: { provider?: string; base?: string; head?: string },
): Promise<GitPrConflicts> {
  const params = new URLSearchParams({
    path: cwd,
    pr_url: prUrl,
  })
  if (opts?.provider) params.set('provider', opts.provider)
  if (opts?.base) params.set('base', opts.base)
  if (opts?.head) params.set('head', opts.head)
  // silent: true — the PR tab renders this failure inline next to the badge,
  // so a toast on top of that would double-report the same problem.
  return await apiFetch<GitPrConflicts>(`/git/pr/conflicts?${params.toString()}`, { silent: true })
}

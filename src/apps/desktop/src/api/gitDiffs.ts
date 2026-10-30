import { apiFetch } from './client'

// Git File Diff API
export interface GitFileDiff {
  path: string
  diff_content: string // Unified diff output from git diff command
  staged: boolean
}

// Batch file diffs — one POST replaces N parallel GET /git/file/diff. Collapses the
// SidebarDiffPanel fan-out (20 files = 20 git spawns holding 20 Io workers) into at most 2
// server-side `git diff` invocations. LIST mode: the client names the paths.
export interface GitFileDiffsBatchItem {
  file: string
  staged: boolean
}

export interface GitFileDiffsResponse {
  diffs: GitFileDiff[]
  /**    * Whole-file mode only: the file's full-context diff exceeded the server's budget and was REFUSED
   * (`diff_content` is empty) rather than truncated into something that reads as a complete file. */
  whole_file_refused?: boolean
}

export async function getGitFileDiffs(
  cwd: string,
  files: GitFileDiffsBatchItem[],
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, files },
    silent: true,
  })
}

// Folder mode — one POST for a whole folder. The server enumerates the changed paths itself (`git
// status --porcelain -uall -- <folder>`), so the caller neither has to fetch `GET /api/git/changes`
// first nor send a path-per-file body.
export async function getGitFolderDiffs(
  cwd: string,
  folder: string = '',
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, folder },
    silent: true,
  })
}

// WHOLE-FILE mode — `git diff -U<all>` for exactly ONE path, so the caller can render every line of
// the file with the changes still marked.
export async function getGitWholeFileDiff(
  cwd: string,
  filePath: string,
  staged: boolean,
): Promise<GitFileDiffsResponse> {
  return await apiFetch<GitFileDiffsResponse>(`/git/file/diffs`, {
    method: 'POST',
    body: { path: cwd, files: [{ file: filePath, staged }], whole_file: true },
    silent: true,
  })
}

export async function readGitFile(
  cwd: string,
  filePath: string,
): Promise<{ content: string; encoding: string }> {
  return await apiFetch<{ content: string; encoding: string }>(
    `/git/file/read?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
  )
}

// Git Stage/Unstage API
export interface GitStageResponse {
  success: boolean
  message: string
  staged_files: string[]
  failed_files: string[]
}

export async function stageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/stage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

export async function unstageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/unstage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

// Git commit API — commits the staged index with a message typed in the
// Files tab's commit box (SidebarDiffPanel). Answers the new HEAD SHA so
// the panel can refresh history without another round-trip.
export interface GitCommitCreateResponse {
  success: boolean
  message: string
  commit_sha: string
}

export async function commitGitChanges(
  cwd: string,
  message: string,
): Promise<GitCommitCreateResponse> {
  return await apiFetch<GitCommitCreateResponse>(
    `/git/commit/create?path=${encodeURIComponent(cwd)}&message=${encodeURIComponent(message)}`,
    { method: 'POST' },
  )
}

import { computed, ref } from 'vue'
import * as api from '../../../api'
import { fetchFolderDiff, folderDiffKey, primeFolderDiffs } from '../../../helpers/folderDiffCache'
import { countDiffLines, parseUnifiedDiff } from './parseUnifiedDiff'
import {
  folderDiffApplied,
  folderDiffErrorList,
  folderDiffTargets,
} from './sidebarDiffLists'
import { moveFileBetweenLists } from './sidebarDiffStage'
import type { PanelDataCommon } from './sidebarDiffTypes'

export function useSidebarDiffGitData(opts: PanelDataCommon) {
  const isGitRepo = ref(false)
  const internalBranch = ref('')
  const stagedFiles = ref<api.GitFileChange[]>([])
  const unstagedFiles = ref<api.GitFileChange[]>([])
  const untrackedFiles = ref<api.GitFileChange[]>([])
  const isLoadingGit = ref(false)
  const gitError = ref<string | null>(null)
  const isStaging = ref(false)

  // ── Per-file +added / -removed ──────────────────────────────────────────── GitHub/GitLab put a
  // line count on every file row; without one a 35-file list is 35 identical-looking paths and the
  // only way to find the big change is to click each.
  const diffCounts = ref(new Map<string, { added: number; removed: number }>())

  const changeCount = computed(
    () => stagedFiles.value.length + unstagedFiles.value.length + untrackedFiles.value.length,
  )

  const loadGitStatus = async () => {
    if (!opts.cwd()) {
      isGitRepo.value = false
      stagedFiles.value = []
      unstagedFiles.value = []
      untrackedFiles.value = []
      diffCounts.value = new Map()
      return
    }
    // Stale-response guard: rapid cwd flips (session → worktree A → B)
    // resolve out of order without this — the slower fetch wins and the
    // panel shows the wrong branch + file list.
    const seq = ++opts.loadSeq.current
    const cwd = opts.cwd()
    isLoadingGit.value = true
    gitError.value = null
    try {
      const data = await api.getGitChanges(cwd)
      if (seq !== opts.loadSeq.current) return
      isGitRepo.value = data.is_git_repo
      internalBranch.value = data.branch || ''
      if (data.is_git_repo) {
        stagedFiles.value = data.staged_files || []
        unstagedFiles.value = data.modified_files || []
        untrackedFiles.value = data.untracked_files || []
        await loadFullList(cwd)
      } else {
        stagedFiles.value = []
        unstagedFiles.value = []
        untrackedFiles.value = []
        diffCounts.value = new Map()
        opts.emit('show-diff-list', [])
      }
    } catch (err) {
      if (seq !== opts.loadSeq.current) return
      diffCounts.value = new Map()
      console.error('Failed to load git status:', err)
      isGitRepo.value = false
      gitError.value = 'Failed to load git status'
    } finally {
      if (seq === opts.loadSeq.current) isLoadingGit.value = false
    }
}

  // Stacked center view: fetch every changed file so the center column renders all diffs without
  // per-click round-trips.
  const loadFullList = async (cwd: string = opts.cwd()) => {
    if (!cwd) return
    const seq = opts.loadSeq.current
    const targets = folderDiffTargets(stagedFiles.value, unstagedFiles.value, untrackedFiles.value)
    if (targets.length === 0) {
      if (seq === opts.loadSeq.current) opts.emit('show-diff-list', [])
      return
    }
    try {
      // Folder mode: the server walks the repo itself, so this body stays
      // three fields wide whether the worktree has 3 dirty files or 300.
      const batch = await api.getGitFolderDiffs(cwd)
      if (seq !== opts.loadSeq.current) return
      const applied = folderDiffApplied(cwd, targets, batch)
      diffCounts.value = applied.counts
      opts.emit('show-diff-list', applied.list)
    } catch (err) {
      // Error rows, not a quieter retry: a visible failure is what stops this
      // from turning back into a silent per-file request storm.
      console.error(`[SidebarDiffPanel] folder diff failed for ${cwd}:`, err)
      if (seq !== opts.loadSeq.current) return
      // Unknown, not zero: the rows must not claim "unchanged" for files
      // whose diff we never received.
      diffCounts.value = new Map()
      opts.emit('show-diff-list', folderDiffErrorList(targets))
    }
}

  const loadDiff = async () => {
    // PR list parses inline (selectPrFile); a center retry there is a no-op.
    if (opts.isPrTab()) return
    if (!opts.cwd() || !opts.selection.path.value) return
    try {
      // `loadFullList` already fetched every changed file in this cwd and primed the shared snapshot,
      // so this is a map read on the hot path.
      const diff = await fetchFolderDiff(opts.cwd(), opts.selection.path.value, opts.selection.staged.value)
      const parsed = parseUnifiedDiff(diff.diff_content)
      opts.emit('show-diff', {
        path: opts.selection.path.value,
        staged: opts.selection.staged.value,
        lines: parsed.lines,
        added: parsed.added,
        removed: parsed.removed,
      })
    } catch (err) {
      console.error('Failed to load file diff:', err)
      opts.emit('show-diff', {
        path: opts.selection.path.value,
        staged: opts.selection.staged.value,
        lines: [],
        added: 0,
        removed: 0,
        error: 'Failed to load file diff',
      })
    }
}

  const selectFile = (file: api.GitFileChange, staged: boolean) => {
    opts.selection.path.value = file.path
    opts.selection.staged.value = staged
    void loadDiff()
}

  // Commit-history file click (GitCommits with inline-file-diff=false): fetch the file's unified diff
  // at that commit and show it in ChatView's center column — the same show-diff flow as worktree/PR
  // file rows. Rename rows carry "old -> new"; the diff is fetched for the new side.
  const onCommitFileClick = async (payload: { commit: api.GitCommit; file: api.GitCommitFile }) => {
    if (!opts.cwd()) return
    const rawPath = payload.file.path
    const diffPath = rawPath.includes(' -> ') ? (rawPath.split(' -> ').pop() ?? rawPath) : rawPath
    opts.selection.path.value = diffPath
    opts.selection.staged.value = false
    try {
      const diff = await api.getGitCommitFileDiff(opts.cwd(), payload.commit.sha, diffPath)
      if (!diff) throw new Error('empty diff')
      const parsed = parseUnifiedDiff(diff.diff_content)
      opts.emit('show-diff', {
        path: diffPath,
        staged: false,
        lines: parsed.lines,
        added: parsed.added,
        removed: parsed.removed,
      })
    } catch (err) {
      console.error('Failed to load commit file diff:', err)
      opts.emit('show-diff', {
        path: diffPath,
        staged: false,
        lines: [],
        added: 0,
        removed: 0,
        error: 'Failed to load commit file diff',
      })
    }
}

  const stageFile = async (file: api.GitFileChange) => {
    if (!opts.cwd() || isStaging.value) return
    isStaging.value = true
    try {
      await api.stageGitFiles(opts.cwd(), [file.path])
      // The SSE event is the primary path: the backend emits `git_file_staged` and
      // `applyFileStageEvent` moves the row.
      applyFileStageEvent({ action: 'staged', path: file.path, cwd: opts.cwd(), failed: false })
    } catch (err) {
      console.error('Failed to stage file:', err)
    } finally {
      isStaging.value = false
    }
}

  const unstageFile = async (file: api.GitFileChange) => {
    if (!opts.cwd() || isStaging.value) return
    isStaging.value = true
    try {
      await api.unstageGitFiles(opts.cwd(), [file.path])
      applyFileStageEvent({ action: 'unstaged', path: file.path, cwd: opts.cwd(), failed: false })
    } catch (err) {
      console.error('Failed to unstage file:', err)
    } finally {
      isStaging.value = false
    }
}

  /**  * Apply one `git_file_stage` SSE event: move the row it names and re-prime only that file's diff
   * and counts. Deliberately does NOT call `loadGitStatus()` — that is the whole point of the
   * channel. The manual ↻ refresh and the commit flow keep the full reload path. */
  function applyFileStageEvent(event: api.GitFileStageEvent): void {
    // A failed git command must not move anything: the row stays where it is
    // and the user sees the file still listed on the side they left it.
    if (event.failed) return
    // One browser tab can show several worktrees; only the panel bound to the
    // event's cwd may move a row.
    if (!opts.cwd() || event.cwd !== opts.cwd()) return
    if (!event.path) return
    // PR mode has no worktree lists to move.
    if (opts.isPrMode()) return

    const moved = moveFileBetweenLists(
      {
        staged: stagedFiles.value,
        unstaged: unstagedFiles.value,
        untracked: untrackedFiles.value,
      },
      event.path,
      event.action,
    )
    stagedFiles.value = moved.staged
    unstagedFiles.value = moved.unstaged
    untrackedFiles.value = moved.untracked

    // Re-prime the one file's diff + counts. `getGitFileDiffs` in LIST mode is
    // one request for one path — not the folder-wide re-fetch the old code did.
    void reprimeFileDiff(event.path, moved.to === 'staged')
    // Keep the centre column's open diff in step with the row that just moved.
    if (opts.selection.path.value === event.path) {
      opts.selection.staged.value = moved.to === 'staged'
      void loadDiff()
    }
}

  /**  * Fetch one file's diff and fold it into the shared snapshot + the row's counts. A failure leaves
   * the previous counts in place rather than showing `+0 -0`, which would read as "this file is
   * unchanged". */
  async function reprimeFileDiff(path: string, staged: boolean): Promise<void> {
    if (!opts.cwd()) return
    try {
      const batch = await api.getGitFileDiffs(opts.cwd(), [{ file: path, staged }])
      const entry = batch.diffs.find((d) => d.path === path && d.staged === staged)
      if (!entry) return
      primeFolderDiffs(opts.cwd(), batch.diffs)
      const { added, removed } = countDiffLines(entry.diff_content)
      const next = new Map(diffCounts.value)
      next.set(folderDiffKey(staged, path), { added, removed })
      diffCounts.value = next
    } catch (err) {
      console.error(`[SidebarDiffPanel] re-prime diff failed for ${path}:`, err)
    }
}

  // Commit box state (Files tab). The message is transient text like the
  // file filter — it lives in a ref, not in the URL, because Back/Forward
  // must never step through keystrokes.
  const commitMessage = ref('')
  const isCommitting = ref(false)
  const commitError = ref('')
  // `git commit` commits the index, so the button needs staged files AND a
  // message. Untracked-only worktrees stay disabled with a hint instead of
  // failing server-side.
  const canCommit = computed(
    () =>
      commitMessage.value.trim().length > 0 &&
      stagedFiles.value.length > 0 &&
      !isCommitting.value &&
      !isStaging.value,
  )

  const commitStaged = async () => {
    if (!opts.cwd() || !canCommit.value) return
    isCommitting.value = true
    commitError.value = ''
    try {
      await api.commitGitChanges(opts.cwd(), commitMessage.value.trim())
      commitMessage.value = ''
      await loadGitStatus()
      await loadDiff()
    } catch (err) {
      console.error('Failed to commit staged changes:', err)
      commitError.value = opts.serverError(err, 'Failed to create commit')
    } finally {
      isCommitting.value = false
    }
}

    return {
      isGitRepo,
      internalBranch,
      stagedFiles,
      unstagedFiles,
      untrackedFiles,
      isLoadingGit,
      gitError,
      isStaging,
      diffCounts,
      changeCount,
      loadGitStatus,
      loadDiff,
      selectFile,
      onCommitFileClick,
      stageFile,
      unstageFile,
      applyFileStageEvent,
      commitMessage,
      isCommitting,
      commitError,
      canCommit,
      commitStaged,
    }
}

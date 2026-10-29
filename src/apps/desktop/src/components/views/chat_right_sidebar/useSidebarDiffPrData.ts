import { computed, ref } from 'vue'
import * as api from '../../../api'
import { conflictsUrl } from '../../../helpers/forgeWording'
import {
  parseUnifiedDiff,
  splitDiffByFile,
  type SplitDiffFile,
} from './parseUnifiedDiff'
import { prSelections } from './sidebarDiffLists'
import { failedChecksOf, prHasConflict } from './sidebarDiffPrView'
import type { PanelDataCommon } from './sidebarDiffTypes'

export function useSidebarDiffPrData(opts: PanelDataCommon) {
  const prFiles = ref<SplitDiffFile[]>([])
  const prBase = ref('')
  const prHead = ref('')
  const prTruncated = ref(false)
  const isLoadingPr = ref(false)
  const prError = ref<string | null>(null)
  // Live merge state from GET /api/git/pr/status (`gh pr view`).
  // Empty = unknown (fetch failed or not yet loaded) — badge hidden.
  const prStatus = ref('')
  const prStatusTitle = ref('')
  /** The whole status payload, not just the derived strings above. */
  const prStatusData = ref<api.GitPrStatus | null>(null)
  // Conflict flag from the same payload (`mergeable`/`merge_state`).
  // Quiet-when-clean: only CONFLICTING/DIRTY surfaces UI; every other
  // value behaves exactly as before (no banner, no badge).
  const prMergeable = ref('')
  const prMergeState = ref('')
  const hasPrConflict = computed(() => prHasConflict(prMergeable.value, prMergeState.value))
  // GitHub renders conflict resolution at <pr-url>/conflicts. GitLab has no
  // such route, so this returns '' there and the notice renders as plain
  // text rather than as a link to a guaranteed 404.
  const prConflictsUrl = computed(() => conflictsUrl(opts.prProvider(), opts.prUrl() ?? ''))
  // Last GET /api/git/pr/status failure, parsed from the server's `{"error": ...}` body. Empty =
  // unknown yet or last fetch worked. Shown inline (the status fetch is silent:true, so no toast) so
  // a `gh` auth / bad-PR-number failure explains itself instead of just hiding the badge.
  const prStatusError = ref('')
  let prSeq = 0

  // Which files the local three-way merge refuses to resolve. Fetched ONLY while `hasPrConflict` is
  // true — a clean PR must cost zero extra spawns and must render byte-identically to before this
  // feature existed.
  const prConflictLoaded = ref(false)
  const prConflictFiles = ref<string[]>([])
  const prConflictError = ref('')
  const prConflictBase = ref('')
  const prConflictTruncated = ref(false)
  let prConflictSeq = 0
  // The in-flight PR diff load, so loadPrConflicts can wait for the base/head it wants to reuse
  // rather than racing that read to empty.
  let prDiffInFlight: Promise<void> | null = null

  const loadPrDiff = async () => {
    if (!opts.cwd() || !opts.isPrMode()) {
      prFiles.value = []
      return
    }
    isLoadingPr.value = true
    prError.value = null
    // Published so loadPrConflicts can wait for base/head instead of racing it
    // (see PR_IN_FLIGHT note there). Tab load runs diff + status in parallel;
    // serialising them would add a full diff round-trip to tab-open latency.
    const run = (async () => {
      try {
        const data = await api.getPrDiff(opts.cwd(), opts.prUrl() ?? '', {
          provider: opts.prProvider() || undefined,
        })
        prFiles.value = splitDiffByFile(data.diff_content)
        prBase.value = data.base || ''
        prHead.value = data.head || ''
        prTruncated.value = data.truncated
        // Stacked center view: every chunk parses synchronously — no
        // per-file fetch needed, the full diff text is already in hand.
        opts.emit('show-diff-list', prSelections(prFiles.value))
      } catch (err) {
        console.error('Failed to load PR diff:', err)
        prError.value = opts.serverError(err, 'Failed to load PR diff')
        prFiles.value = []
      }
    })()
    prDiffInFlight = run
    try {
      await run
    } finally {
      if (prDiffInFlight === run) prDiffInFlight = null
      isLoadingPr.value = false
    }
}

  // Merge-state sync: `gh pr view` via GET /api/git/pr/status. Runs alongside loadPrDiff on every
  // PR-tab load and on a 30s poll while the PR tab is visible, so a GitHub merge flips the badge
  // without a manual refresh.
  const loadPrStatus = async () => {
    if (!opts.cwd() || !opts.isPrMode()) {
      prStatus.value = ''
      prStatusTitle.value = ''
      prMergeable.value = ''
      prMergeState.value = ''
      prStatusError.value = ''
      prStatusData.value = null
      return
    }
    const seq = ++prSeq
    try {
      const data = await api.getPrStatus(opts.cwd(), opts.prUrl() ?? '', {
        provider: opts.prProvider() || undefined,
      })
      if (seq !== prSeq) return
      prStatus.value = (data.status || data.state || '').toLowerCase()
      prStatusTitle.value = data.title || ''
      prMergeable.value = data.mergeable || ''
      prMergeState.value = data.merge_state || ''
      prStatusData.value = data
      prStatusError.value = ''
      // The conflict badge just turned on or off — re-derive the file list in
      // the same turn so the section never lags the badge by a render.
      await loadPrConflicts()
    } catch (err) {
      if (seq !== prSeq) return
      prStatus.value = ''
      prStatusTitle.value = ''
      prMergeable.value = ''
      prMergeState.value = ''
      prStatusData.value = null
      prStatusError.value = opts.serverError(err, 'Failed to load PR status')
      await loadPrConflicts()
    }
}

  /**  * A merge landed (or was accepted) — re-read NOW. The poll would pick it up within 30 s, but the
   * user just took a destructive action and the badge has to agree with it immediately; a PR still
   * reading "Open" one second after "Confirm and merge" looks like the merge failed. */
  const onMerged = () => {
    void loadPrStatus()
}

  const retryPr = () => {
    void loadPrDiff()
    void loadPrStatus()
}

  // Which files conflict, per `git merge-tree` on the local refs. Called
  // right after loadPrStatus resolves a conflict, and again whenever the merge
  // state flips — never speculatively, so the clean-PR path is unchanged.
  const loadPrConflicts = async () => {
    if (!opts.cwd() || !opts.isPrMode() || !hasPrConflict.value) {
      // Clear too: the PR may have just been merged/rebased clean, and a stale
      // list under a badge that vanished would be a lie in the other direction.
      prConflictLoaded.value = false
      prConflictFiles.value = []
      prConflictError.value = ''
      prConflictBase.value = ''
      prConflictTruncated.value = false
      return
    }
    const seq = ++prConflictSeq
    // Wait for the diff load so base/head below are the exact refs the file
    // list above was computed from. loadPrDiff already renders its own error.
    const pendingDiff = prDiffInFlight
    if (pendingDiff) {
      try {
        await pendingDiff
      } catch {
        /* diff error is shown by the PR tab itself */
      }
      if (seq !== prConflictSeq) return
    }
    try {
      const data = await api.getPrConflicts(opts.cwd(), opts.prUrl() ?? '', {
        provider: opts.prProvider() || undefined,
        base: prBase.value || undefined,
        head: prHead.value || undefined,
      })
      if (seq !== prConflictSeq) return
      prConflictFiles.value = data.conflicting_files || []
      prConflictBase.value = data.base_ref || ''
      prConflictTruncated.value = !!data.truncated
      prConflictError.value = ''
      prConflictLoaded.value = true
    } catch (err) {
      if (seq !== prConflictSeq) return
      prConflictFiles.value = []
      prConflictBase.value = ''
      prConflictTruncated.value = false
      prConflictError.value = opts.serverError(err, 'Failed to compute conflicting files')
      prConflictLoaded.value = true
    }
}

  /** Drop the conflict list and invalidate any in-flight read (the PR binding changed). */
  function resetConflicts() {
    prConflictSeq++
    prConflictLoaded.value = false
    prConflictFiles.value = []
    prConflictError.value = ''
    prConflictBase.value = ''
    prConflictTruncated.value = false
  }

  // The forge says CONFLICTING but our local merge came back clean. Almost always a stale local base
  // ref (we deliberately never `git fetch`). Showing an empty list next to a red badge would read as
  // "nothing to do", so say so instead and point at the ref the answer was computed from.
  const prConflictUnreproduced = computed(
    () => prConflictLoaded.value && !prConflictError.value && prConflictFiles.value.length === 0,
  )

  const selectPrFile = (file: SplitDiffFile) => {
    opts.selection.path.value = file.path
    opts.selection.staged.value = false
    const parsed = parseUnifiedDiff(file.text)
    opts.emit('show-diff', {
      path: file.path,
      staged: false,
      lines: parsed.lines,
      added: parsed.added,
      removed: parsed.removed,
    })
}

    return {
      prFiles,
      prBase,
      prHead,
      prTruncated,
      isLoadingPr,
      prError,
      prStatus,
      prStatusTitle,
      prStatusData,
      prMergeable,
      prMergeState,
      prStatusError,
      prConflictLoaded,
      prConflictFiles,
      prConflictError,
      prConflictBase,
      prConflictTruncated,
      hasPrConflict,
      prConflictsUrl,
      prConflictUnreproduced,
      failedChecksCount: computed(() => failedChecksOf(prStatusData.value)),
      loadPrDiff,
      loadPrStatus,
      loadPrConflicts,
      onMerged,
      retryPr,
      selectPrFile,
      resetConflicts,
    }
}

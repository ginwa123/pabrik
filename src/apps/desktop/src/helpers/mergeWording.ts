/**
 * The merge box's state machine and its method vocabulary.
 *
 * Two jobs, one table each, for the reason `forgeWording.ts` exists: three
 * components each hardcoding prose is how the `<pr-url>/conflicts` 404
 * happened. Here the stakes are higher than a wrong word — this table decides
 * whether the merge button may be pressed at all.
 *
 * THE INPUT IS ALREADY ON THE WIRE. `GET /api/git/pr/status` returns
 * `mergeable` and `merge_state` on every poll (the PR tab polls it every
 * 30 s while it is visible), so the box needs no extra request to know
 * whether it can merge and why not. The Checks tab is not an option: it is
 * `v-if`-mounted only when clicked, so on the PR tab its data does not exist.
 *
 * WHAT THE TWO FIELDS MEAN
 *   GitHub   merge_state = `mergeStateStatus`, the forge's own verdict
 *            (CLEAN / UNSTABLE / BLOCKED / BEHIND / DIRTY / DRAFT /
 *            HAS_HOOKS / UNKNOWN); mergeable = MERGEABLE / CONFLICTING /
 *            UNKNOWN.
 *   GitLab   merge_state = `merge_status`, mergeable = `detailed_merge_status`
 *            (the closer analogue of mergeStateStatus).
 *
 * An unrecognised value resolves to `pending` — never to `ready`. A forge that
 * adds a vocabulary word must not be able to turn a disabled button into a
 * merge.
 */
import type { ForgeWording } from './forgeWording'

export type MergeBoxState = 'ready' | 'caution' | 'blocked' | 'pending' | 'merged' | 'closed'

export interface MergeWording {
  state: MergeBoxState
  /** Sentence-case headline. Always rendered. */
  headline: string
  /** The second line: why, in the forge's own terms. `''` when the headline says it. */
  detail: string
  /** Whether the primary button may be pressed. */
  canMerge: boolean
}

export interface MergeSignals {
  /** Normalized status from the endpoint: open | closed | merged | locked | ''. */
  status: string
  mergeable: string
  mergeState: string
  forge: ForgeWording
  /** The branch the merge targets, for "into main". */
  baseRef?: string
}

const eq = (a: string, b: string) => a.trim().toUpperCase() === b

/** GitHub's `mergeStateStatus`, by its documented values. */
function githubState(mergeState: string, mergeable: string, s: MergeSignals): MergeWording | null {
  const mergeableIsConflict = eq(mergeable, 'CONFLICTING')
  if (mergeState === '') return null
  if (eq(mergeState, 'DIRTY') || mergeableIsConflict) {
    return {
      state: 'blocked',
      headline: 'This branch has conflicts',
      detail: 'Conflicts must be resolved before merging.',
      canMerge: false,
    }
  }
  if (eq(mergeState, 'DRAFT')) {
    return {
      state: 'blocked',
      headline: 'This is still a draft',
      detail: `Mark it ready for review on ${s.forge.forge}.`,
      canMerge: false,
    }
  }
  if (eq(mergeState, 'BLOCKED')) {
    return {
      state: 'blocked',
      headline: 'Merging is blocked',
      detail: 'Required approvals or checks are missing.',
      canMerge: false,
    }
  }
  if (eq(mergeState, 'UNSTABLE')) {
    return {
      state: 'caution',
      headline: 'Some checks were not successful',
      detail: `Merging is still allowed on ${s.forge.forge}.`,
      canMerge: true,
    }
  }
  if (eq(mergeState, 'BEHIND')) {
    return {
      state: 'caution',
      headline: 'This branch is out of date',
      detail: 'It can still be merged, or updated first.',
      canMerge: true,
    }
  }
  if (eq(mergeState, 'HAS_HOOKS')) {
    return {
      state: 'caution',
      headline: 'Merging can be performed',
      detail: 'A pre-receive hook may still reject it.',
      canMerge: true,
    }
  }
  if (eq(mergeState, 'CLEAN')) {
    return {
      state: 'ready',
      headline: 'All checks have passed',
      detail: `No conflicts with ${s.baseRef || 'the base branch'}. Merging can be performed automatically.`,
      canMerge: true,
    }
  }
  // UNKNOWN, and anything a future gh adds.
  return null
}

/** GitLab's `detailed_merge_status`, by its documented values. */
function gitlabState(mergeable: string, s: MergeSignals): MergeWording | null {
  const v = mergeable.trim().toLowerCase()
  if (v === '') return null
  if (v === 'mergeable') {
    return {
      state: 'ready',
      headline: 'All checks have passed',
      detail: `No conflicts with ${s.baseRef || 'the target branch'}. Merging can be performed automatically.`,
      canMerge: true,
    }
  }
  if (v === 'conflict' || v === 'conflicted' || v === 'not_mergeable') {
    return {
      state: 'blocked',
      headline: 'This branch has conflicts',
      detail: 'Conflicts must be resolved before merging.',
      canMerge: false,
    }
  }
  if (v === 'draft_status' || v === 'wip') {
    return {
      state: 'blocked',
      headline: 'This is still a draft',
      detail: `Mark it ready for review on ${s.forge.forge}.`,
      canMerge: false,
    }
  }
  if (v === 'not_approved' || v === 'requested_changes' || v === 'discussions_not_resolved') {
    return {
      state: 'blocked',
      headline: 'Merging is blocked',
      detail: 'This merge request is not approved yet.',
      canMerge: false,
    }
  }
  if (
    v === 'ci_must_pass' ||
    v === 'ci_still_running' ||
    v === 'status_checks_must_pass' ||
    v === 'status_checks_still_running'
  ) {
    return {
      state: 'blocked',
      headline: 'Merging is blocked',
      detail: 'Required checks have not passed.',
      canMerge: false,
    }
  }
  if (v === 'need_rebase') {
    return {
      state: 'caution',
      headline: 'This branch is out of date',
      detail: 'It can still be merged, or rebased first.',
      canMerge: true,
    }
  }
  if (
    v === 'blocked_status' ||
    v === 'merge_request_blocked' ||
    v === 'security_policies_violations'
  ) {
    return {
      state: 'blocked',
      headline: 'Merging is blocked',
      detail: 'Required approvals or checks are missing.',
      canMerge: false,
    }
  }
  // checking / preparations / unchecked / title_regex_mismatch / anything new.
  return null
}

const PENDING: MergeWording = {
  state: 'pending',
  headline: 'Merge status is being calculated',
  detail: 'The forge has not finished checking. Refresh shortly.',
  canMerge: false,
}

/** The box's whole state, from the two fields the poll already carries. */
/** `merged` and `closed` short-circuit first: a merged PR's mergeable state is meaningless (GitHub
 * reports UNKNOWN for it), and rendering "Merge status is being calculated" over a merged pull
 * request is the class of lie this module exists to prevent. */
export function mergeWording(s: MergeSignals): MergeWording {
  const status = (s.status || '').trim().toLowerCase()
  if (status === 'merged') {
    return { state: 'merged', headline: 'Merged', detail: '', canMerge: false }
  }
  if (status === 'closed' || status === 'locked') {
    return {
      state: 'closed',
      headline: `This ${s.forge.noun} is closed`,
      detail: `Reopen it on ${s.forge.forge} to merge.`,
      canMerge: false,
    }
  }
  const found =
    s.forge.program === 'glab'
      ? (gitlabState(s.mergeable, s) ?? gitlabState(s.mergeState, s))
      : githubState(s.mergeState, s.mergeable, s)
  return found ?? PENDING
}

// ── The method menu ───────────────────────────────────────────────────────
export type MergeMethod = 'merge' | 'squash' | 'rebase'

/**  * The three methods both CLIs expose. `gh pr merge` needs exactly one of them — with no strategy
 * flag it prompts, and a non-tty child cannot answer. Order is GitHub's. */
export const MERGE_METHODS: readonly MergeMethod[] = ['merge', 'squash', 'rebase'] as const

export function methodLabel(m: MergeMethod): string {
  if (m === 'merge') return 'Create a merge commit'
  if (m === 'rebase') return 'Rebase and merge'
  return 'Squash and merge'
}

export function methodDetail(m: MergeMethod, target: string): string {
  if (m === 'merge') return `All commits will be added to ${target} with a merge commit.`
  if (m === 'rebase') return `The commits will be rebased onto ${target}.`
  return `The commits will be combined into one commit in ${target}.`
}

const METHOD_KEY = 'pabrik-pr-merge-method'

/** A stable key for "this repository": everything between the host and the change request, e.g.
 * `ginwa123/pabrik` on GitHub and `g/sub/repo` on GitLab (a GitLab project path keeps its nested
 * namespace). The same repo reached through two worktrees therefore remembers ONE method choice. */
/** The `(?:-\/)?` is load-bearing: GitLab inserts a `/-/` discriminator before `merge_requests`,
 * and a pattern that ignored it would key the memory on the project name alone — colliding with a
 * same-named project elsewhere. */
export function repoKeyFor(prUrl: string, fallback: string): string {
  const m = /^https?:\/\/[^/]+\/(.+?)\/(?:-\/)?(?:pull|merge_requests)\/\d+/.exec(
    (prUrl || '').trim(),
  )
  const path = m?.[1]
  return path ? path.replace(/\.git$/, '') : fallback
}

/** The last method used for this repo, or `squash`. Squash is the default because it is what this
 * project actually does: every merged PR in this repo so far was squashed, so a merge commit as the
 * default would be wrong more often than right. */
/** The choice is remembered per repo, so the second merge onwards is one click. */
export function rememberedMethod(key: string): MergeMethod {
  try {
    if (typeof localStorage === 'undefined') return 'squash'
    const raw = localStorage.getItem(`${METHOD_KEY}:${key}`)
    return MERGE_METHODS.includes(raw as MergeMethod) ? (raw as MergeMethod) : 'squash'
  } catch {
    return 'squash'
  }
}

export function rememberMethod(key: string, method: MergeMethod): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(`${METHOD_KEY}:${key}`, method)
  } catch {
    // A full or disabled localStorage must not break a merge.
  }
}

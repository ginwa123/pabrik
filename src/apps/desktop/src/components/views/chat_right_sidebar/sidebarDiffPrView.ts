import type { GitPrStatus } from '../../../api'

export const prHasConflict = (mergeable: string, mergeState: string): boolean => {
  const m = (mergeable || '').toUpperCase()
  const s = (mergeState || '').toUpperCase()
  // GitHub says CONFLICTING / DIRTY.
  if (m === 'CONFLICTING') return true
  if (s === 'DIRTY') return true
  // GitLab's `detailed_merge_status` has its own vocabulary. Without these rows a conflicted MR
  // renders as mergeable, which is the worst direction to be wrong in — the user is told to merge
  // something that cannot merge.
  if (m === 'CONFLICTED') return true
  if (m === 'NOT_MERGEABLE') return true
  return false
}

// Badge text/color for the live merge state. Unknown state hides it.
export const prStatusLabelOf = (status: string): string => {
  if (status === 'merged') return 'Merged'
  if (status === 'closed') return 'Closed'
  if (status === 'open') return 'Open'
  return ''
}

export const prStatusStyleOf = (status: string): { backgroundColor: string; color: string } => {
  if (status === 'merged') return { backgroundColor: 'var(--color-violet)', color: 'var(--color-bg)' }
  if (status === 'closed')
    return { backgroundColor: 'var(--semantic-error)', color: 'var(--color-bg)' }
  return { backgroundColor: 'var(--color-green)', color: 'var(--color-bg)' }
}

// The request's own words. The number is a lookup key; the title is what
// a reviewer reads first, and it was nowhere on the screen.
export const prTitleOf = (data: GitPrStatus | null, title: string): string =>
  data?.title ?? title ?? ''

export const prAuthorOf = (data: GitPrStatus | null): string => data?.author ?? ''
export const prHeadRefOf = (data: GitPrStatus | null, head: string): string =>
  data?.head_ref ?? head ?? ''
export const prBaseRefOf = (data: GitPrStatus | null, base: string): string =>
  data?.base_ref ?? base ?? ''

// The chips: two doors into the two tabs that hold the reasons.
export const failedChecksOf = (data: GitPrStatus | null): number => data?.checks?.failed ?? 0

export const reviewChipOf = (
  data: GitPrStatus | null,
): { label: string; title: string } | null => {
  const decision = (data?.review_decision ?? '').toUpperCase()
  if (decision === 'CHANGES_REQUESTED')
    return { label: 'Changes requested', title: 'A reviewer asked for changes' }
  if (decision === 'REVIEW_REQUIRED')
    return { label: 'Review requested', title: 'This change request still needs a review' }
  return null
}

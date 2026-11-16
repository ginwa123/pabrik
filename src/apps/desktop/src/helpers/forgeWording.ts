/** Provider-aware wording for the PR/MR surface. */
export interface ForgeWording {
  noun: string
  short: string
  label: string
  forge: string
  /** The CLI the backend spawns for this forge (`gh` / `glab`). */
  program: string
  /** True when the forge has no `<url>/conflicts` page to link to. */
  hasConflictPage: boolean
}

const GITHUB: ForgeWording = {
  noun: 'pull request',
  short: 'PR',
  label: 'Pull request',
  forge: 'GitHub',
  program: 'gh',
  hasConflictPage: true,
}

const GITLAB: ForgeWording = {
  noun: 'merge request',
  short: 'MR',
  label: 'Merge request',
  forge: 'GitLab',
  program: 'glab',
  // GitLab resolves conflicts inline on the MR page itself.
  hasConflictPage: false,
}

/** Wording for `provider`, defaulting to GitHub when it is empty or unrecognised. */
export function forgeWording(provider?: string | null): ForgeWording {
  return provider === 'gitlab' ? GITLAB : GITHUB
}

/** Detect the forge from a PR/MR URL, for callers that never got a provider. */
export function forgeFromPrUrl(prUrl?: string | null): ForgeWording {
  if (prUrl && prUrl.includes('/-/merge_requests/')) return GITLAB
  return GITHUB
}

/** The URL that shows this change request's conflicts, or `''` when the forge has no such page. */
export function conflictsUrl(provider: string | undefined, prUrl: string): string {
  const wording = forgeWording(provider)
  if (!wording.hasConflictPage || !prUrl) return ''
  return `${prUrl.replace(/\/$/, '')}/conflicts`
}

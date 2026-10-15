/**
 * Provider-aware wording for the PR/MR surface.
 *
 * The backend stores a provider per attached change request
 * (`sessions.pr_provider`) and now answers `GET /api/git/pr/status` for
 * GitLab as well as GitHub. The UI has to follow, because "pull request"
 * is not a GitLab user's word — they say "merge request" — and two of the
 * constructs this module used to emit are outright wrong on GitLab:
 *
 *  - `<pr-url>/conflicts` is a GitHub-only route. GitLab has no such
 *    path; a link built that way is a guaranteed 404.
 *  - `<repo>/tree/<branch>` is GitHub-only. GitLab inserts a `/-/`
 *    discriminator, so its branch page is `<repo>/-/tree/<branch>`.
 *
 * One table, used by every component, is the only way those two stay
 * correct; the bug this replaces was three components each hardcoding
 * `github.com` prose.
 */
/** The vocabulary of one forge. `noun` is sentence case, `short` is caps. */
export interface ForgeWording {
  noun: string
  short: string
  label: string
  forge: string
  /**    * The CLI the backend spawns for this forge (`gh` / `glab`). Needed for error text: naming `gh`
   * in a failure a GitLab user triggered is the same class of bug as telling them to install gh. */
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
/** Defaulting matters: `pr_provider` is empty on every session created before GitLab support
 * existed, and those are all GitHub — so an unknown provider is a known-GitHub one far more often
 * than not, and guessing wrong is cosmetic while guessing blank is not. */
export function forgeWording(provider?: string | null): ForgeWording {
  return provider === 'gitlab' ? GITLAB : GITHUB
}

/** Detect the forge from a PR/MR URL, for callers that never got a provider. */
export function forgeFromPrUrl(prUrl?: string | null): ForgeWording {
  if (prUrl && prUrl.includes('/-/merge_requests/')) return GITLAB
  return GITHUB
}

/**  * The URL that shows this change request's conflicts, or `''` when the forge has no such page.
 * Returning `''` makes the caller render plain text instead of a link that 404s — an honest dead
 * end beats a broken link that looks live. */
export function conflictsUrl(provider: string | undefined, prUrl: string): string {
  const wording = forgeWording(provider)
  if (!wording.hasConflictPage || !prUrl) return ''
  return `${prUrl.replace(/\/$/, '')}/conflicts`
}

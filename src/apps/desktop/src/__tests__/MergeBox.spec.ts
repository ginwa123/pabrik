/**
 * MergeBox — the merge button's own contract.
 *
 * Two rules this file exists to protect:
 *
 *   1. A state that may not merge must SAY WHY, visibly. "Disabled with a
 *      tooltip" is unreachable at the panel's 200px minimum and unreadable in
 *      a screenshot; the reason is the headline's second line.
 *   2. A CLI that exits 0 without merging is not a merge. The box renders the
 *      server's `pending` as "not merged yet" and never as "Merged", because
 *      `glab mr merge` can return 0 having only armed auto-merge and a GitHub
 *      merge queue accepts a PR without merging it.
 *
 * The state table is asserted directly as well: it is the product (the words
 * and the enabled/disabled verdict the user reads), not an implementation
 * detail, and one case per row of it is what keeps a forge's new vocabulary
 * word from silently becoming "mergeable".
 */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import MergeBox from '../components/views/chat_right_sidebar/MergeBox.vue'
import {
  mergeWording,
  methodDetail,
  methodLabel,
  rememberedMethod,
  rememberMethod,
  repoKeyFor,
  type MergeMethod,
} from '../helpers/mergeWording'
import { forgeWording } from '../helpers/forgeWording'
import { clearPrStatusCache, fetchPrStatusCached } from '../helpers/prStatusCache'

const { mergePrMock, getPrStatusMock } = vi.hoisted(() => ({
  mergePrMock: vi.fn(),
  getPrStatusMock: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, mergePr: mergePrMock, getPrStatus: getPrStatusMock }
})

const GH = forgeWording('github')
const GL = forgeWording('gitlab')

/** A status payload shaped like the endpoint's, with overrides per test. */
function status(over: Partial<Record<string, unknown>> = {}) {
  return {
    provider: 'github',
    pr_url: 'https://github.com/ginwa123/pabrik/pull/891',
    number: 891,
    title: 'Scroll restore',
    state: 'OPEN',
    status: 'open',
    mergeable: 'MERGEABLE',
    merge_state: 'CLEAN',
    head_sha: '4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e',
    head_ref: 'worktree/add-a-button',
    base_ref: 'main',
    author: 'ginwa123',
    created_at: '',
    updated_at: '',
    merged_at: '',
    closed_at: '',
    additions: 1,
    deletions: 2,
    changed_files: 3,
    ...over,
  } as never
}

const state = (over: Partial<Record<string, unknown>> = {}) =>
  mergeWording({
    status: (over.status as string) ?? 'open',
    mergeable: (over.mergeable as string) ?? '',
    mergeState: (over.mergeState as string) ?? '',
    forge: (over.forge as typeof GH) ?? GH,
    baseRef: (over.baseRef as string) ?? 'main',
  })

// jsdom in this vitest does not provide localStorage cleanly — `window.localStorage` is undefined
// even at a valid origin. That is a known quirk of this suite, worked around in exactly this way by
// navigation.spec.ts.

// The stand-in is installed on the bare global because that is what the app's own code reads
// (useChatRightSidebar.ts).
beforeEach(() => {
  mergePrMock.mockReset()
  getPrStatusMock.mockReset()
  // The shared PR-status cache is module-level, and the merge test below
  // primes it — reset so no test inherits another's entry.
  clearPrStatusCache()
  if (typeof localStorage === 'undefined' || typeof localStorage.clear !== 'function') {
    const store: Record<string, string> = {}
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = String(v)
      },
      removeItem: (k: string) => {
        delete store[k]
      },
      clear: () => {
        for (const k in store) delete store[k]
      },
      key: () => null,
      length: 0,
    })
  } else {
    localStorage.clear()
  }
})

// ── the state table, one case per row ────────────────────────────────────
describe('mergeWording', () => {
  it('GitHub CLEAN is ready and names the base branch', () => {
    const w = state({ mergeState: 'CLEAN' })
    expect(w.state).toBe('ready')
    expect(w.canMerge).toBe(true)
    expect(w.headline).toBe('All checks have passed')
    expect(w.detail).toContain('main')
  })

  it('GitHub UNSTABLE may still merge, and says so', () => {
    const w = state({ mergeState: 'UNSTABLE' })
    expect(w.state).toBe('caution')
    expect(w.canMerge).toBe(true)
    expect(w.headline).toBe('Some checks were not successful')
  })

  it('GitHub BEHIND and HAS_HOOKS are cautions that still merge', () => {
    expect(state({ mergeState: 'BEHIND' }).canMerge).toBe(true)
    expect(state({ mergeState: 'BEHIND' }).headline).toBe('This branch is out of date')
    expect(state({ mergeState: 'HAS_HOOKS' }).canMerge).toBe(true)
  })

  it('GitHub BLOCKED, DIRTY and DRAFT are blocked with a visible reason', () => {
    for (const [ms, headline] of [
      ['BLOCKED', 'Merging is blocked'],
      ['DIRTY', 'This branch has conflicts'],
      ['DRAFT', 'This is still a draft'],
    ] as const) {
      const w = state({ mergeState: ms })
      expect(w.state).toBe('blocked')
      expect(w.canMerge).toBe(false)
      expect(w.headline).toBe(headline)
      // Rule 1: a blocked state always renders a second line.
      expect(w.detail.length).toBeGreaterThan(0)
    }
  })

  it('a CONFLICTING mergeable blocks even when mergeStateStatus says otherwise', () => {
    expect(state({ mergeState: 'CLEAN', mergeable: 'CONFLICTING' }).canMerge).toBe(false)
  })

  it('GitHub UNKNOWN is pending, not ready', () => {
    const w = state({ mergeState: 'UNKNOWN' })
    expect(w.state).toBe('pending')
    expect(w.canMerge).toBe(false)
  })

  it('a vocabulary word we do not know is pending, never ready', () => {
    // The honest failure direction: a forge that adds a state must not be able
    // to turn a disabled button into a merge.
    expect(state({ mergeState: 'SOMETHING_NEW' }).state).toBe('pending')
    expect(state({ mergeState: 'SOMETHING_NEW' }).canMerge).toBe(false)
    expect(state({ mergeState: '' }).state).toBe('pending')
  })

  it('GitLab detailed_merge_status maps onto the same four states', () => {
    expect(state({ mergeable: 'mergeable', forge: GL }).state).toBe('ready')
    expect(state({ mergeable: 'conflict', forge: GL }).headline).toBe('This branch has conflicts')
    expect(state({ mergeable: 'draft_status', forge: GL }).headline).toBe('This is still a draft')
    expect(state({ mergeable: 'not_approved', forge: GL }).canMerge).toBe(false)
    expect(state({ mergeable: 'ci_must_pass', forge: GL }).canMerge).toBe(false)
    expect(state({ mergeable: 'need_rebase', forge: GL }).state).toBe('caution')
    expect(state({ mergeable: 'checking', forge: GL }).state).toBe('pending')
    expect(state({ mergeable: 'something_new', forge: GL }).canMerge).toBe(false)
  })

  it('a merged or closed change request never renders a merge verdict', () => {
    expect(state({ status: 'merged', mergeState: 'UNKNOWN' }).state).toBe('merged')
    expect(state({ status: 'closed' }).canMerge).toBe(false)
    expect(state({ status: 'closed' }).headline).toContain('pull request')
    expect(state({ status: 'closed', forge: GL }).headline).toContain('merge request')
  })
})

// ── the method memory ────────────────────────────────────────────────────
describe('the method menu', () => {
  it('offers the three methods both CLIs accept, in GitHub order', () => {
    expect(methodLabel('merge')).toBe('Create a merge commit')
    expect(methodLabel('squash')).toBe('Squash and merge')
    expect(methodLabel('rebase')).toBe('Rebase and merge')
    expect(methodDetail('squash', 'main')).toContain('main')
  })

  it('defaults to squash and remembers the choice per repo', () => {
    expect(rememberedMethod('ginwa123/pabrik')).toBe('squash')
    rememberMethod('ginwa123/pabrik', 'rebase')
    expect(rememberedMethod('ginwa123/pabrik')).toBe('rebase')
    // A different repo has its own memory.
    expect(rememberedMethod('ginwa123/kabelweb')).toBe('squash')
  })

  it('keys the memory on owner/repo, for both forges', () => {
    expect(repoKeyFor('https://github.com/ginwa123/pabrik/pull/891', '/tmp/x')).toBe(
      'ginwa123/pabrik',
    )
    // A GitLab project path keeps its nested namespace.
    expect(repoKeyFor('https://gitlab.com/g/sub/repo/-/merge_requests/7', '/tmp/x')).toBe(
      'g/sub/repo',
    )
    // No PR URL yet: fall back to the directory.
    expect(repoKeyFor('', '/tmp/x')).toBe('/tmp/x')
  })

  it('a corrupt stored value falls back to squash instead of throwing', () => {
    localStorage.setItem('pabrik-pr-merge-method:ginwa123/pabrik', 'nonsense')
    expect(rememberedMethod('ginwa123/pabrik')).toBe('squash')
  })
})

// ── the component ────────────────────────────────────────────────────────
const props = {
  cwd: '/tmp/repo',
  prUrl: 'https://github.com/ginwa123/pabrik/pull/891',
  prProvider: 'github',
}

describe('MergeBox', () => {
  it('renders nothing until the status payload has arrived', () => {
    const w = mount(MergeBox, { props: { ...props, status: null } })
    expect(w.find('[data-testid="pr-merge-box"]').exists()).toBe(false)
  })

  it('a ready PR offers the squash default, with the method caret', () => {
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    expect(w.get('[data-testid="pr-merge-headline"]').text()).toBe('All checks have passed')
    expect(w.get('[data-testid="pr-merge-button"]').text()).toBe('Squash and merge')
    expect(w.get('[data-testid="pr-merge-button"]').attributes('disabled')).toBeUndefined()
    expect(w.find('[data-testid="pr-merge-caret"]').exists()).toBe(true)
  })

  it('a blocked PR disables the button and renders the reason in words', () => {
    const w = mount(MergeBox, { props: { ...props, status: status({ merge_state: 'BLOCKED' }) } })
    const btn = w.get('[data-testid="pr-merge-button"]')
    expect(btn.attributes('disabled')).toBeDefined()
    expect(w.get('[data-testid="pr-merge-headline"]').text()).toBe('Merging is blocked')
    expect(w.get('[data-testid="pr-merge-detail"]').text()).toBe(
      'Required approvals or checks are missing.',
    )
    // No method menu on a PR that cannot be merged.
    expect(w.find('[data-testid="pr-merge-caret"]').exists()).toBe(false)
  })

  it('the menu opens with all three methods and picking one relabels the button', async () => {
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    expect(w.find('[data-testid="pr-merge-menu"]').exists()).toBe(false)
    await w.get('[data-testid="pr-merge-caret"]').trigger('click')
    expect(w.find('[data-testid="pr-merge-menu"]').exists()).toBe(true)
    for (const m of ['merge', 'squash', 'rebase'] as MergeMethod[]) {
      expect(w.find(`[data-testid="pr-merge-method-${m}"]`).exists()).toBe(true)
    }
    await w.get('[data-testid="pr-merge-method-rebase"]').trigger('click')
    expect(w.find('[data-testid="pr-merge-menu"]').exists()).toBe(false)
    expect(w.get('[data-testid="pr-merge-button"]').text()).toBe('Rebase and merge')
  })

  it('delete-branch is OFF by default and the branch is named next to it', () => {
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    const box = w.get('[data-testid="pr-merge-delete-branch"]').element as HTMLInputElement
    // Pre-ticking it could delete the branch the user's session stands on.
    expect(box.checked).toBe(false)
    expect(w.text()).toContain('worktree/add-a-button')
  })

  it('the confirm step names the method and the target branch, then posts the body', async () => {
    mergePrMock.mockResolvedValue({
      success: true,
      method: 'squash',
      pending: false,
      status: status({ status: 'merged', state: 'MERGED' }),
    })
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    await w.get('[data-testid="pr-merge-button"]').trigger('click')
    expect(w.get('[data-testid="pr-merge-confirm-heading"]').text()).toBe(
      'Squash and merge into main',
    )
    // The default commit message is the PR's own title + number.
    expect((w.get('[data-testid="pr-merge-message"]').element as HTMLTextAreaElement).value).toBe(
      'Scroll restore (#891)',
    )

    await w.get('[data-testid="pr-merge-confirm"]').trigger('click')
    await flushPromises()

    expect(mergePrMock).toHaveBeenCalledTimes(1)
    // Assert the whole call in one shot: the endpoint, the change request, and
    // the body. `toHaveBeenCalledWith` also keeps this type-safe (an indexed
    // `mock.calls[0]` is `possibly undefined` under this tsconfig).
    expect(mergePrMock).toHaveBeenCalledWith(
      '/tmp/repo',
      props.prUrl,
      expect.objectContaining({
        method: 'squash',
        // The head guard: the commit the user was looking at.
        head_sha: '4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e4f21c9e',
        delete_branch: false,
      }),
    )
    // The owner is told, so it can re-read the status instead of waiting 30 s.
    expect(w.emitted('merged')).toBeTruthy()
    expect(w.find('[data-testid="pr-merge-pending"]').exists()).toBe(false)
  })

  it('drops the shared PR-status cache for the head branch, so the badges re-read', async () => {
    // The bug this asserts against: the sidebar RECENT icon and the kanban card
    // badge read the shared 60s cache, so after a merge from this box they kept
    // the `open` green they had fetched before the click.
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    await expect(fetchPrStatusCached(props.cwd, 'worktree/add-a-button')).resolves.toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)

    mergePrMock.mockResolvedValue({
      success: true,
      method: 'squash',
      pending: false,
      status: status({ status: 'merged', state: 'MERGED' }),
    })
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    await w.get('[data-testid="pr-merge-button"]').trigger('click')
    await w.get('[data-testid="pr-merge-confirm"]').trigger('click')
    await flushPromises()

    // The next reader must ask the forge again — and see the merge.
    getPrStatusMock.mockResolvedValue({ status: 'merged', state: 'MERGED' })
    await expect(fetchPrStatusCached(props.cwd, 'worktree/add-a-button')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('exit 0 without a merge renders "not merged yet", never a success', async () => {
    // The case this component exists to get right.
    mergePrMock.mockResolvedValue({
      success: false,
      method: 'squash',
      pending: true,
      status: status(),
    })
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    await w.get('[data-testid="pr-merge-button"]').trigger('click')
    await w.get('[data-testid="pr-merge-confirm"]').trigger('click')
    await flushPromises()
    const notice = w.get('[data-testid="pr-merge-pending"]')
    expect(notice.text()).toContain('has not merged it yet')
    expect(notice.text()).not.toContain('Merged ')
  })

  it('a refusal renders the server’s own words above the button', async () => {
    mergePrMock.mockRejectedValue(
      new Error('Pull request is not mergeable: the base branch requires approvals'),
    )
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    await w.get('[data-testid="pr-merge-button"]').trigger('click')
    await w.get('[data-testid="pr-merge-confirm"]').trigger('click')
    await flushPromises()
    expect(w.get('[data-testid="pr-merge-error"]').text()).toContain('not mergeable')
    // The confirm step stays open so the user can see the reason next to it.
    expect(w.find('[data-testid="pr-merge-confirm"]').exists()).toBe(true)
    expect(w.emitted('merged')).toBeFalsy()
  })

  it('cancel returns to the button without posting', async () => {
    const w = mount(MergeBox, { props: { ...props, status: status() } })
    await w.get('[data-testid="pr-merge-button"]').trigger('click')
    await w.get('[data-testid="pr-merge-cancel"]').trigger('click')
    await flushPromises()
    expect(w.find('[data-testid="pr-merge-confirm"]').exists()).toBe(false)
    expect(w.get('[data-testid="pr-merge-button"]').text()).toBe('Squash and merge')
    expect(mergePrMock).not.toHaveBeenCalled()
  })

  it('a GitLab MR uses MR wording and the remembered method', async () => {
    rememberMethod('g/sub/repo', 'merge')
    const w = mount(MergeBox, {
      props: {
        cwd: '/tmp/repo',
        prUrl: 'https://gitlab.com/g/sub/repo/-/merge_requests/7',
        prProvider: 'gitlab',
        status: status({
          provider: 'gitlab',
          pr_url: 'https://gitlab.com/g/sub/repo/-/merge_requests/7',
          mergeable: 'not_approved',
          merge_state: 'cannot_be_merged',
        }),
      },
    })
    expect(w.get('[data-testid="pr-merge-headline"]').text()).toBe('Merging is blocked')
    expect(w.get('[data-testid="pr-merge-detail"]').text()).toBe(
      'This merge request is not approved yet.',
    )
    expect(w.get('[data-testid="pr-merge-button"]').attributes('disabled')).toBeDefined()
  })
})

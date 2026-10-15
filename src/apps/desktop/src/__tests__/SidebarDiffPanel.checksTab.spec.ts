/**  * The Checks tab's URL contract. Every view switch must land in the URL, or refresh / Back-Forward
 * / shared links lose the view. The commits tab first shipped as a local boolean and had exactly
 * that bug; the Checks tab reuses the same `?panel=` union rather than inventing a second param. */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../components/views/chat_right_sidebar/SidebarDiffPanel.vue'
import { clearFolderDiffCache } from '../helpers/folderDiffCache'

// The panel's children fetch on mount; stub them so the spec is about the
// tab contract, not about the network.
vi.mock('../components/git/GitCommits.vue', () => ({
  default: { name: 'GitCommits', template: '<div data-testid="git-commits-stub" />' },
}))
vi.mock('../components/views/chat_right_sidebar/PrChecksPanel.vue', () => ({
  default: {
    name: 'PrChecksPanel',
    props: ['cwd', 'prUrl', 'prProvider'],
    template: '<div data-testid="pr-checks-stub" />',
  },
}))
vi.mock('../components/views/chat_right_sidebar/SkillEvalsPanel.vue', () => ({
  default: {
    name: 'SkillEvalsPanel',
    props: ['sessionId'],
    template: '<div data-testid="skill-evals-stub" />',
  },
}))
vi.mock('../api', async () => {
  // Spreads the real module: SidebarDiffPanel reaches for `api.ApiError`, and
  // a partial mock without it throws from inside a catch block.
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    getGitChanges: vi
      .fn()
      .mockResolvedValue({
        is_git_repo: true,
        branch: 'main',
        staged_files: [],
        modified_files: [],
        untracked_files: [],
      }),
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    getPrDiff: vi
      .fn()
      .mockResolvedValue({ pr_url: '', base: '', head: '', diff_content: '', truncated: false }),
    getPrStatus: vi
      .fn()
      .mockResolvedValue({
        status: 'open',
        state: 'OPEN',
        title: '',
        mergeable: '',
        merge_state: '',
      }),
    getPrChecks: vi.fn().mockResolvedValue({ checks: [], summary: {} }),
    getSkillEvalsRuns: vi.fn().mockResolvedValue({ runs: [], results: [] }),
    getSkillEvalsSummary: vi.fn().mockResolvedValue({ counts: [], total: 0 }),
    applySkillEvalResult: vi.fn().mockResolvedValue({ applied: true }),
  }
})

async function makeRouter(query: Record<string, string> = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div />' } }],
  })
  await router.push({ path: '/', query })
  await router.isReady()
  return router
}

async function mountPanel(
  router: Awaited<ReturnType<typeof makeRouter>>,
  props: Record<string, unknown> = {},
) {
  const wrapper = mount(SidebarDiffPanel, {
    props: { cwd: '/tmp/repo', ...props },
    global: { plugins: [router] },
  })
  await flushPromises()
  return wrapper
}

const PR_URL = 'https://github.com/acme/app/pull/42'

describe('SidebarDiffPanel — the Checks tab', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
  })

  it('is reachable without an attached PR', async () => {
    // CI is about the forge, not about the diff, so the tab must not be
    // gated behind PR mode.
    const w = await mountPanel(await makeRouter())
    expect(w.find('[data-testid="sidebar-tab-checks"]').exists()).toBe(true)
  })

  it('writes ?panel=checks when clicked', async () => {
    const router = await makeRouter({ pr: PR_URL })
    const w = await mountPanel(router, { prUrl: PR_URL })
    await w.find('[data-testid="sidebar-tab-checks"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.panel).toBe('checks')
  })

  it('restores the Checks tab from ?panel=checks on mount', async () => {
    const w = await mountPanel(await makeRouter({ panel: 'checks' }), { prUrl: PR_URL })
    expect(w.find('[data-testid="pr-checks-stub"]').exists()).toBe(true)
    expect(w.find('[data-testid="sidebar-tab-checks"]').attributes('aria-selected')).toBe('true')
  })

  it('does not render the Checks panel when another tab is selected', async () => {
    const w = await mountPanel(await makeRouter({ panel: 'commits' }), { prUrl: PR_URL })
    expect(w.find('[data-testid="pr-checks-stub"]').exists()).toBe(false)
  })

  it('passes the PR ref and provider down to the panel', async () => {
    const w = await mountPanel(await makeRouter({ panel: 'checks' }), {
      prUrl: PR_URL,
      prProvider: 'github',
    })
    const panel = w.findComponent({ name: 'PrChecksPanel' })
    expect(panel.props('prUrl')).toBe(PR_URL)
    expect(panel.props('prProvider')).toBe('github')
  })
})

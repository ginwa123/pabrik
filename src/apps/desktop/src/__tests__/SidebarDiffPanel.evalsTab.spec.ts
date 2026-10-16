/** The Evals tab's URL contract. Every view switch must land in the URL, or refresh / Back-Forward
 * / shared links lose the view. The commits tab first shipped as a local boolean and had exactly
 * that bug; the Evals tab reuses the same `?panel=` union rather than inventing a second param. */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import SidebarDiffPanel from '../components/views/chat_right_sidebar/SidebarDiffPanel.vue'

// The panel's children fetch on mount; stub them so the spec is about the
// tab contract, not about the network.
vi.mock('../components/git/GitCommits.vue', () => ({
  default: { name: 'GitCommits', template: '<div data-testid="git-commits-stub" />' },
}))
vi.mock('../components/views/chat_right_sidebar/SkillEvalsPanel.vue', () => ({
  default: {
    name: 'SkillEvalsPanel',
    props: ['sessionId'],
    template: '<div data-testid="skill-evals-stub" />',
  },
}))
vi.mock('../api', () => ({
  getGitChanges: vi.fn().mockResolvedValue({ files: [], branch: 'main' }),
  getGitStatus: vi.fn().mockResolvedValue({ is_repo: true, branch: 'main' }),
  getPrDiff: vi.fn().mockResolvedValue({ files: [] }),
  getPrStatus: vi.fn().mockResolvedValue({ state: '' }),
  getSkillEvalsRuns: vi.fn().mockResolvedValue({ runs: [], results: [] }),
  getSkillEvalsSummary: vi.fn().mockResolvedValue({ counts: [], total: 0 }),
  applySkillEvalResult: vi.fn().mockResolvedValue({ applied: true }),
}))

function makeRouter() {
  return createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div />' } }],
  })
}

async function mountPanel(router: ReturnType<typeof makeRouter>, query: Record<string, string> = {}) {
  await router.push({ path: '/', query })
  await router.isReady()
  return mount(SidebarDiffPanel, {
    props: { cwd: '/tmp/repo' },
    global: { plugins: [router] },
  })
}

describe('SidebarDiffPanel — the Evals tab', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('is reachable without an attached PR', async () => {
    // The Evals tab is about the agent's self-assessment, not about the
    // diff, so it must not be gated behind PR mode.
    const router = makeRouter()
    const wrapper = await mountPanel(router)
    expect(wrapper.find('[data-testid="sidebar-tab-evals"]').exists()).toBe(true)
  })

  it('writes ?panel=evals when clicked', async () => {
    const router = makeRouter()
    const wrapper = await mountPanel(router)
    await wrapper.find('[data-testid="sidebar-tab-evals"]').trigger('click')
    // `router.replace` is async; let the navigation settle before reading.
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(router.currentRoute.value.query.panel).toBe('evals')
  })

  it('restores the Evals tab from ?panel=evals on mount', async () => {
    const router = makeRouter()
    const wrapper = await mountPanel(router, { panel: 'evals' })
    expect(wrapper.find('[data-testid="skill-evals-stub"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-tab-evals"]').attributes('aria-selected')).toBe(
      'true',
    )
  })

  it('does not render the Evals panel when another tab is selected', async () => {
    const router = makeRouter()
    const wrapper = await mountPanel(router, { panel: 'commits' })
    expect(wrapper.find('[data-testid="skill-evals-stub"]').exists()).toBe(false)
  })
})

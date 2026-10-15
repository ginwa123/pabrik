/** Git icon right-click menu: open GitHub branch / PR URLs in a new tab.
 * Covers the URL helpers (repo base + branch URL derivation) and the
 * GitBranchMenu items (disabled when the URL is missing). */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import {
  repoBaseFromPrUrl,
  branchUrlFromPrUrl,
  fetchPrInfoCached,
  clearPrStatusCache,
} from '../helpers/prStatusCache'
import GitBranchMenu from '../components/shell/GitBranchMenu.vue'

const { getPrStatusMock } = vi.hoisted(() => ({
  getPrStatusMock: vi.fn(),
}))

vi.mock('@/api', async () => {
  const actual = await vi.importActual<typeof import('@/api')>('@/api')
  return {
    ...actual,
    getPrStatus: getPrStatusMock,
  }
})

describe('git branch URLs', () => {
  beforeEach(() => {
    clearPrStatusCache()
    vi.clearAllMocks()
    vi.spyOn(console, 'warn').mockImplementation(() => {})
  })

  it('derives the repo base from a PR URL', () => {
    expect(repoBaseFromPrUrl('https://github.com/acme/app/pull/42')).toBe(
      'https://github.com/acme/app',
    )
  })

  it('returns empty for a non-PR URL', () => {
    expect(repoBaseFromPrUrl('https://github.com/acme/app')).toBe('')
    expect(repoBaseFromPrUrl('')).toBe('')
  })

  it('builds the branch URL from the PR repo base', () => {
    expect(branchUrlFromPrUrl('https://github.com/acme/app/pull/42', 'feature/x')).toBe(
      'https://github.com/acme/app/tree/feature%2Fx',
    )
  })

  it('returns empty branch URL when there is no PR URL', () => {
    expect(branchUrlFromPrUrl('', 'feature/x')).toBe('')
  })

  it('fetchPrInfoCached keeps the pr_url alongside the status', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      pr_url: 'https://github.com/acme/app/pull/42',
    })
    const info = await fetchPrInfoCached('/repo', 'feature/x')
    expect(info.status).toBe('open')
    expect(info.prUrl).toBe('https://github.com/acme/app/pull/42')
    await flushPromises()
  })
})

describe('GitBranchMenu', () => {
  const teleportStub = { global: { stubs: { teleport: true } } }

  it('renders both items enabled when URLs are present', () => {
    const wrapper = mount(GitBranchMenu, {
      props: {
        x: 10,
        y: 20,
        branch: 'feature/x',
        branchUrl: 'https://github.com/acme/app/tree/feature%2Fx',
        prUrl: 'https://github.com/acme/app/pull/42',
      },
      ...teleportStub,
    })
    const branchItem = wrapper.find('[data-testid="open-branch-new-tab-item"]')
    const prItem = wrapper.find('[data-testid="open-pr-new-tab-item"]')
    expect(branchItem.exists()).toBe(true)
    expect(prItem.exists()).toBe(true)
    expect(branchItem.attributes('disabled')).toBeUndefined()
    expect(prItem.attributes('disabled')).toBeUndefined()
  })

  it('disables items when URLs are missing', () => {
    const wrapper = mount(GitBranchMenu, {
      props: { x: 10, y: 20, branch: 'feature/x', branchUrl: '', prUrl: '' },
      ...teleportStub,
    })
    expect(
      wrapper.find('[data-testid="open-branch-new-tab-item"]').attributes('disabled'),
    ).toBeDefined()
    expect(
      wrapper.find('[data-testid="open-pr-new-tab-item"]').attributes('disabled'),
    ).toBeDefined()
  })

  it('emits openBranch / openPr on click', async () => {
    const wrapper = mount(GitBranchMenu, {
      props: {
        x: 10,
        y: 20,
        branch: 'feature/x',
        branchUrl: 'https://github.com/acme/app/tree/feature%2Fx',
        prUrl: 'https://github.com/acme/app/pull/42',
      },
      ...teleportStub,
    })
    await wrapper.find('[data-testid="open-branch-new-tab-item"]').trigger('click')
    await wrapper.find('[data-testid="open-pr-new-tab-item"]').trigger('click')
    expect(wrapper.emitted('openBranch')).toBeTruthy()
    expect(wrapper.emitted('openPr')).toBeTruthy()
  })
})

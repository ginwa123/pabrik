/** PrChecksPanel — the panel's own contract. The rule this file exists to protect: "this PR has no
 * failing checks" and "we could not reach the backend" must render differently. */
/** A `catch { return [] }` would make an unreachable backend look like a green build, which is the
 * one wrong answer a CI panel can give. */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import PrChecksPanel from '../components/views/chat_right_sidebar/PrChecksPanel.vue'

const { getPrChecksMock } = vi.hoisted(() => ({ getPrChecksMock: vi.fn() }))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, getPrChecks: getPrChecksMock }
})

const CHECKS = {
  provider: 'github',
  pr_url: 'https://github.com/acme/app/pull/42',
  steps_truncated: false,
  summary: { total: 3, passed: 1, failed: 1, pending: 1, skipped: 0, cancelled: 0 },
  checks: [
    {
      name: 'backend (Windows X64) / build',
      workflow: 'ci',
      bucket: 'fail',
      state: 'FAILURE',
      link: 'https://github.com/acme/app/actions/runs/1/job/2',
      started_at: '',
      completed_at: '',
      steps_error: '',
      steps: [
        {
          name: 'Set up job',
          number: 1,
          conclusion: 'success',
          status: 'completed',
          started_at: '',
          completed_at: '',
        },
        {
          name: 'zig build test',
          number: 3,
          conclusion: 'failure',
          status: 'completed',
          started_at: '',
          completed_at: '',
        },
      ],
    },
    {
      name: 'lint (oxlint + eslint)',
      workflow: 'ci',
      bucket: 'pass',
      state: 'SUCCESS',
      link: 'https://github.com/acme/app/actions/runs/1/job/3',
      started_at: '',
      completed_at: '',
      steps_error: '',
      steps: [],
    },
    {
      name: 'android-test (ubuntu-24.04)',
      workflow: 'ci',
      bucket: 'pending',
      state: 'IN_PROGRESS',
      link: '',
      started_at: '',
      completed_at: '',
      steps_error: '',
      steps: [],
    },
  ],
}

async function mountPanel(props: Record<string, unknown> = {}) {
  const wrapper = mount(PrChecksPanel, {
    props: { cwd: '/repo', prUrl: 'https://github.com/acme/app/pull/42', ...props },
  })
  await flushPromises()
  return wrapper
}

describe('PrChecksPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getPrChecksMock.mockResolvedValue(CHECKS)
  })

  it('renders one row per check job', async () => {
    const w = await mountPanel()
    // Assert on the row-name testids rather than on a composed row id:
    // job names contain `(`, `+` and `/`, and a querySelector built from
    // them is needlessly fragile.
    const names = w.findAll('[data-testid="checks-row-name"]').map((n) => n.text())
    expect(names).toHaveLength(3)
    expect(names).toContain('backend (Windows X64) / build')
    expect(names).toContain('lint (oxlint + eslint)')
    expect(names).toContain('android-test (ubuntu-24.04)')
  })

  it('shows the failing STEP of a failed job, not just the job', async () => {
    const w = await mountPanel()
    // Failing jobs are expanded by default — the user opened this tab to
    // read them, and a collapsed red row answers nothing.
    expect(w.find('[data-testid="checks-step-zig build test"]').exists()).toBe(true)
    expect(w.find('[data-testid="checks-step-Set up job"]').exists()).toBe(true)
  })

  it('sorts failures to the top', async () => {
    const w = await mountPanel()
    const names = w.findAll('[data-testid="checks-row-name"]').map((n) => n.text())
    expect(names[0]).toContain('backend (Windows X64)')
  })

  it('summarises the tally', async () => {
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-failed-count"]').text()).toBe('1 failed')
  })

  it('collapses a failed job when the user clicks the toggle', async () => {
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-step-zig build test"]').exists()).toBe(true)
    await w.find('[data-testid="checks-toggle-backend (Windows X64) / build"]').trigger('click')
    expect(w.find('[data-testid="checks-step-zig build test"]').exists()).toBe(false)
  })

  it('renders a steps_error instead of silently showing no steps', async () => {
    getPrChecksMock.mockResolvedValue({
      ...CHECKS,
      summary: { total: 1, passed: 0, failed: 1, pending: 0, skipped: 0, cancelled: 0 },
      checks: [
        {
          name: 'backend (Linux X64) / build',
          workflow: 'ci',
          bucket: 'fail',
          state: 'FAILURE',
          link: 'https://github.com/acme/app/actions/runs/1/job/9',
          started_at: '',
          completed_at: '',
          steps: [],
          steps_error: 'run lookup timed out',
        },
      ],
    })
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-steps-error"]').text()).toContain('run lookup timed out')
  })

  it('surfaces a failed fetch as an error, NOT as an empty check list', async () => {
    // The bug this guards: `catch { checks.value = [] }` makes an
    // unreachable backend render as "No CI checks reported", i.e. green.
    getPrChecksMock.mockRejectedValue(new Error('gh: could not connect'))
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-error"]').text()).toContain('could not connect')
    expect(w.find('[data-testid="checks-empty"]').exists()).toBe(false)
  })

  it('distinguishes "no CI at all" from "fetch failed"', async () => {
    getPrChecksMock.mockResolvedValue({
      provider: 'github',
      pr_url: '42',
      steps_truncated: false,
      summary: { total: 0, passed: 0, failed: 0, pending: 0, skipped: 0, cancelled: 0 },
      checks: [],
    })
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-empty"]').exists()).toBe(true)
    expect(w.find('[data-testid="checks-error"]').exists()).toBe(false)
  })

  it('warns when the backend could only read some jobs’ steps', async () => {
    getPrChecksMock.mockResolvedValue({ ...CHECKS, steps_truncated: true })
    const w = await mountPanel()
    expect(w.find('[data-testid="checks-truncated"]').exists()).toBe(true)
  })

  it('does not fetch when no PR is attached', async () => {
    await mountPanel({ prUrl: '' })
    expect(getPrChecksMock).not.toHaveBeenCalled()
  })

  it('links each job to the forge', async () => {
    const w = await mountPanel()
    const link = w.findAll('[data-testid="checks-row-link"]')[0]
    expect(link?.attributes('href')).toBe('https://github.com/acme/app/actions/runs/1/job/2')
  })
})

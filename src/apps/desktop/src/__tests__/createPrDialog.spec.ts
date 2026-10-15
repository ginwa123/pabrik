/**
 * Tests for CreatePrDialog.vue — the "Create a pull request" modal
 * mounted by ChatView when the user clicks "Create a PR" in the
 * WorktreeMenu.
 *
 * The component is async at three points:
 *   1. onMounted: fetches worktree info to pre-fill title/body
 *   2. Auto-fill button: re-fetches with the CURRENT base branch
 *      so the diff is computed against whatever the user has typed
 *   3. Submit: posts the PR via api.createGitPr and emits
 *      `pr-created` (with the URL) or `error`
 *
 * The component has 4 `data-testid`s:
 *   - `create-pr-base`     — the base-branch <input>
 *   - `create-pr-title`    — the PR-title <input>
 *   - `create-pr-body`     — the PR-body <textarea>
 *   - `create-pr-submit`   — the violet "Create PR" submit button
 *   - `create-pr-regenerate` — the ↻ Auto-fill button
 *
 * Guards the Chunk 6 wiring:
 *   - On-mount fetch uses `api.getGitWorktreeInfo(worktreePath)` with
 *     NO `base` argument (the backend falls back to its default-base
 *     detection)
 *   - Auto-fill re-fetches with `api.getGitWorktreeInfo(worktreePath,
 *     base.value)` — the second arg is the user's CURRENT base
 *   - Submit emits `pr-created` on success, `error` on failure
 *   - The submit button is gated on `title.trim() !== ''`
 *   - All action buttons disable while submitting or regenerating
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'

import * as api from '../api'
import CreatePrDialog from '../components/dialogs/CreatePrDialog.vue'

// Realistic payload the backend returns. Field names match
// `GitWorktreeInfo` in api/index.ts.
function makeInfo(overrides: Partial<api.GitWorktreeInfo> = {}): api.GitWorktreeInfo {
  return {
    is_git_repo: true,
    branch: 'worktree/feature-x',
    last_commit_sha: 'abc1234',
    last_commit_msg: 'old title',
    default_base: 'main',
    commits_ahead: 1,
    diff_summary: 'old diff',
    draft_title: 'old title',
    draft_body: 'old body',
    ...overrides,
  }
}

describe('CreatePrDialog', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('on mount calls api.getGitWorktreeInfo with NO base arg and pre-fills the form', async () => {
    const spy = vi
      .spyOn(api, 'getGitWorktreeInfo')
      .mockResolvedValue(
        makeInfo({
          default_base: 'develop',
          draft_title: 'My new PR title',
          draft_body: 'My new PR body',
        }),
      )

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    // First call must have only one arg (worktreePath). The component's
    // onMounted does NOT pass a base — it relies on the backend's
    // default-base detection.
    expect(spy).toHaveBeenCalledTimes(1)
    expect(spy.mock.calls[0]![0]).toBe('/tmp/wt')
    expect(spy.mock.calls[0]![1]).toBeUndefined()

    // The form must be pre-filled with the response.
    const titleEl = wrapper.find('[data-testid="create-pr-title"]')
      .element as HTMLInputElement
    const bodyEl = wrapper.find('[data-testid="create-pr-body"]')
      .element as HTMLTextAreaElement
    const baseEl = wrapper.find('[data-testid="create-pr-base"]')
      .element as HTMLInputElement

    expect(titleEl.value).toBe('My new PR title')
    expect(bodyEl.value).toBe('My new PR body')
    expect(baseEl.value).toBe('develop')
  })

  it('auto-fill button re-fetches with the current base branch', async () => {
    // This is the verbose test from the plan's Step 8.2 — copy the
    // structure exactly so the regression coverage matches the spec.
    const spy = vi
      .spyOn(api, 'getGitWorktreeInfo')
      .mockResolvedValueOnce({
        // first call (onMounted)
        is_git_repo: true,
        branch: 'worktree/feature-x',
        last_commit_sha: 'abc1234',
        last_commit_msg: 'old title',
        default_base: 'main',
        commits_ahead: 1,
        diff_summary: 'old diff',
        draft_title: 'old title',
        draft_body: 'old body',
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)
      .mockResolvedValueOnce({
        // second call (auto-fill click)
        is_git_repo: true,
        branch: 'worktree/feature-x',
        last_commit_sha: 'def5678',
        last_commit_msg: 'new title',
        default_base: 'develop',
        commits_ahead: 5,
        diff_summary: 'new diff',
        draft_title: 'new title',
         
        draft_body: 'new body',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    // Simulate the user changing the base branch
    const baseInput = wrapper.find('[data-testid="create-pr-base"]')
    await baseInput.setValue('develop')

    // Click auto-fill
    await wrapper.find('[data-testid="create-pr-regenerate"]').trigger('click')
    await flushPromises()

    // The second call must have been made with base='develop'
    expect(spy).toHaveBeenCalledTimes(2)
    expect(spy.mock.calls[1]![1]).toBe('develop')

    // Title + body should reflect the second response
    const titleEl = wrapper.find('[data-testid="create-pr-title"]')
      .element as HTMLInputElement
    const bodyEl = wrapper.find('[data-testid="create-pr-body"]')
      .element as HTMLTextAreaElement
    expect(titleEl.value).toBe('new title')
    expect(bodyEl.value).toBe('new body')
  })

  it('the Auto-fill button is disabled while submitting', async () => {
    // Hold the createGitPr promise open so isSubmitting stays true.
    // Then verify the regenerate button has the `disabled` attribute.
    let resolveCreate: (v: api.GitPrCreateResponse) => void = () => {}
    const createPromise = new Promise<api.GitPrCreateResponse>((res) => {
      resolveCreate = res
    })
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(makeInfo({ draft_title: 'Hello' }))
    vi.spyOn(api, 'createGitPr').mockReturnValue(createPromise)

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    // Trigger submit, then verify regenerate is disabled mid-flight.
    await wrapper.find('[data-testid="create-pr-submit"]').trigger('click')
    await nextTick()

    const regenBtn = wrapper.find('[data-testid="create-pr-regenerate"]')
      .element as HTMLButtonElement
    expect(regenBtn.disabled).toBe(true)

    // Resolve the create promise so cleanup runs.
    resolveCreate({ success: true, pr_url: 'https://example/pr/1', error: '' })
    await flushPromises()
  })

  it('the Auto-fill button is disabled while a regenerate is in flight', async () => {
    // Hold the getGitWorktreeInfo response open so isRegenerating
    // stays true. Then verify the regenerate button is disabled.
    let resolveRegen: (v: api.GitWorktreeInfo) => void = () => {}
    const regenPromise = new Promise<api.GitWorktreeInfo>((res) => {
      resolveRegen = res
    })
    // The onMounted call resolves immediately (so the form populates),
    // but the auto-fill click holds open.
    vi.spyOn(api, 'getGitWorktreeInfo')
      .mockResolvedValueOnce(makeInfo())
      .mockReturnValueOnce(regenPromise)

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    // Click Auto-fill, then verify it's disabled while in flight.
    await wrapper.find('[data-testid="create-pr-regenerate"]').trigger('click')
    await nextTick()

    const regenBtn = wrapper.find('[data-testid="create-pr-regenerate"]')
      .element as HTMLButtonElement
    expect(regenBtn.disabled).toBe(true)

    resolveRegen(makeInfo({ draft_title: 'regen', draft_body: 'regen' }))
    await flushPromises()
  })

  it('clicking "Create PR" calls api.createGitPr and emits pr-created on success', async () => {
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(
      makeInfo({ draft_title: 'My PR', draft_body: 'My body' }),
    )
    const createSpy = vi
      .spyOn(api, 'createGitPr')
      .mockResolvedValue({ success: true, pr_url: 'https://example.com/pr/42', error: '' })

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    await wrapper.find('[data-testid="create-pr-submit"]').trigger('click')
    await flushPromises()

    // createGitPr should have been called with (worktreePath, base, title, body).
    expect(createSpy).toHaveBeenCalledTimes(1)
    expect(createSpy.mock.calls[0]![0]).toBe('/tmp/wt')
    expect(createSpy.mock.calls[0]![2]).toBe('My PR')
    expect(createSpy.mock.calls[0]![3]).toBe('My body')

    // The dialog should emit pr-created with the URL.
    expect(wrapper.emitted('pr-created')).toBeTruthy()
    expect(wrapper.emitted('pr-created')![0]).toEqual(['https://example.com/pr/42'])
    // No error event on success.
    expect(wrapper.emitted('error')).toBeFalsy()
  })

  it('on createGitPr HTTP failure, emits error and keeps the dialog open', async () => {
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(
      makeInfo({ draft_title: 'My PR', draft_body: 'My body' }),
    )
    // The component's `onSubmit` wraps `createGitPr` in try/catch —
    // any thrown error (e.g. an HTTP failure from the backend) emits
    // `error`. The dialog does NOT close; the user can fix and retry.
    vi.spyOn(api, 'createGitPr').mockRejectedValue(new Error('HTTP 500: gh not installed'))

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    await wrapper.find('[data-testid="create-pr-submit"]').trigger('click')
    await flushPromises()

    expect(wrapper.emitted('error')).toBeTruthy()
    // The error message should mention the underlying HTTP failure.
    expect(wrapper.emitted('error')![0]![0]).toMatch(/500|HTTP|gh not installed/i)
    // No pr-created event on failure.
    expect(wrapper.emitted('pr-created')).toBeFalsy()
    // The dialog must still be visible (the wrapper still exists and
    // the submit button is still in the DOM).
    expect(wrapper.find('[data-testid="create-pr-submit"]').exists()).toBe(true)
  })

  it('on createGitPr success=false, emits error with the response error', async () => {
    // The backend can return HTTP 500 with `{success: false, error: ...}`
    // (e.g. when `gh pr create` exited non-zero). The component must
    // handle this distinctly from an exception.
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(
      makeInfo({ draft_title: 'My PR', draft_body: 'My body' }),
    )
    vi.spyOn(api, 'createGitPr').mockResolvedValue({
      success: false,
      pr_url: '',
      error: 'gh: not authenticated',
    })

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    await wrapper.find('[data-testid="create-pr-submit"]').trigger('click')
    await flushPromises()

    expect(wrapper.emitted('error')).toBeTruthy()
    expect(wrapper.emitted('error')![0]![0]).toContain('gh: not authenticated')
    expect(wrapper.emitted('pr-created')).toBeFalsy()
  })

  it('the submit button is disabled when title is empty', async () => {
    // Pre-fill an empty title so the submit button stays disabled.
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(
      makeInfo({ draft_title: '', draft_body: 'body' }),
    )
    vi.spyOn(api, 'createGitPr').mockResolvedValue({
      success: true,
      pr_url: 'https://example/pr/1',
      error: '',
    })

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    const submitBtn = wrapper.find('[data-testid="create-pr-submit"]')
      .element as HTMLButtonElement
    expect(submitBtn.disabled).toBe(true)

    // Sanity-check the inverse: type a title, the button enables.
    await wrapper.find('[data-testid="create-pr-title"]').setValue('A title')
    const enabledBtn = wrapper.find('[data-testid="create-pr-submit"]')
      .element as HTMLButtonElement
    expect(enabledBtn.disabled).toBe(false)
  })

  it('the close button is disabled while submitting', async () => {
    // Hold the createGitPr promise open so isSubmitting stays true.
    let resolveCreate: (v: api.GitPrCreateResponse) => void = () => {}
    const createPromise = new Promise<api.GitPrCreateResponse>((res) => {
      resolveCreate = res
    })
    vi.spyOn(api, 'getGitWorktreeInfo').mockResolvedValue(makeInfo({ draft_title: 'Hello' }))
    vi.spyOn(api, 'createGitPr').mockReturnValue(createPromise)

    wrapper = mount(CreatePrDialog, {
      props: { worktreePath: '/tmp/wt' },
      attachTo: document.body,
    })
    await flushPromises()

    await wrapper.find('[data-testid="create-pr-submit"]').trigger('click')
    await nextTick()

    // The plan specifies `data-testid="create-pr-submit"` on the submit button. The close (✕)
    // button in the dialog header is NOT given a testid in the production code, so identify it as
    // the button with text content `Cancel` (in the footer) and the ✕ (in the header).
    // Both bind `:disabled="isSubmitting"`.
    const buttons = wrapper.findAll('button')
    const cancelBtn = buttons.find((b) => b.text() === 'Cancel')!
    const closeBtn = buttons.find((b) => b.text().trim() === '✕')!
    expect((cancelBtn.element as HTMLButtonElement).disabled).toBe(true)
    expect((closeBtn.element as HTMLButtonElement).disabled).toBe(true)

    resolveCreate({ success: true, pr_url: 'https://example/pr/1', error: '' })
    await flushPromises()
  })
})

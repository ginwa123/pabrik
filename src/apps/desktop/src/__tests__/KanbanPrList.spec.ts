/**
 * Behavioural tests for KanbanPrList — the board-level
 * change-request list.
 *
 * The critical distinction (PR-#719 bug class): a failed forge call
 * must render `pr-list-error`, never the empty state. An empty list
 * is ONLY rendered when the request resolved with `changes: []`.
 */
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { defineComponent } from 'vue'
import KanbanPrList from '../components/kanban/KanbanPrList.vue'
import { ApiError } from '../api'
import type { GitPrListItem, GitPrListResponse } from '../api'
import type { Task } from '../stores/workspaces'

const { listPrsMock, closePrMock } = vi.hoisted(() => ({
  listPrsMock: vi.fn(),
  closePrMock: vi.fn(),
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listPrs: listPrsMock,
    closePr: closePrMock,
  }
})

// ConfirmDialog teleports to `body`, which escapes the wrapper — stub it in place so the confirm
// flow stays queryable. The `pr-close-confirm` testid lives on the wrapper div in KanbanPrList's
// own template, so it survives stubbing.
const ConfirmDialogStub = defineComponent({
  props: ['show', 'title', 'message', 'confirmText', 'cancelText'],
  emits: ['close', 'confirm'],
  template: `
    <div v-if="show" data-testid="pr-close-confirm-dialog">
      <div data-testid="pr-close-confirm-title">{{ title }}</div>
      <div data-testid="pr-close-confirm-message">{{ message }}</div>
      <button data-testid="pr-close-confirm-yes" @click="$emit('confirm'); $emit('close')">{{ confirmText }}</button>
      <button data-testid="pr-close-confirm-no" @click="$emit('close')">{{ cancelText }}</button>
    </div>`,
})

const makeRow = (overrides: Partial<GitPrListItem> = {}): GitPrListItem => ({
  number: 909,
  title: 'fix(settings): remove redundant workspace-name box',
  url: 'https://github.com/ginwa123/pabrik/pull/909',
  state: 'open',
  is_draft: false,
  head_ref: 'worktree/feat-x',
  base_ref: 'main',
  author: 'ginwa123',
  updated_at: '2026-10-12T06:34:01Z',
  ...overrides,
})

const makeListResponse = (changes: GitPrListItem[]): GitPrListResponse => ({
  provider: 'github',
  program: 'gh',
  state: 'open',
  truncated: false,
  detail: '',
  changes,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'Board card',
  git_branch: 'worktree/feat-x',
  kanban_column_id: 'col_1',
  ...overrides,
})

function mountList(
  opts: {
    rows?: GitPrListItem[]
    tasks?: Task[]
    tab?: 'open' | 'closed'
  } = {},
) {
  if (opts.rows !== undefined) listPrsMock.mockResolvedValue(makeListResponse(opts.rows))
  return mount(KanbanPrList, {
    props: {
      itemPath: '/repo',
      itemId: 'item_1',
      workspaceId: 'ws_1',
      tasks: opts.tasks ?? [makeTask()],
      open: true,
      tab: opts.tab ?? 'open',
    },
    global: {
      stubs: {
        ConfirmDialog: ConfirmDialogStub,
        ForgeIcon: true,
        UiIcon: true,
      },
    },
  })
}

const closeButtonIn = (wrapper: VueWrapper, rowTestId: string) => {
  const row = wrapper.find(`[data-testid="${rowTestId}"]`)
  const btn = row.findAll('button').find((b) => b.text() === 'Close' || b.text() === 'Closing…')
  if (!btn) throw new Error(`no Close button in ${rowTestId}`)
  return btn
}

describe('KanbanPrList', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    closePrMock.mockResolvedValue({
      closed: true,
      detail: '',
      provider: 'github',
      status: {},
    })
  })

  it('shows loading first, then rows with the board-join badge', async () => {
    let resolveList!: (v: GitPrListResponse) => void
    listPrsMock.mockReturnValue(
      new Promise<GitPrListResponse>((resolve) => {
        resolveList = resolve
      }),
    )
    const wrapper = mountList({
      tasks: [makeTask({ name: 'Board card', git_branch: 'worktree/feat-x' })],
    })
    expect(wrapper.find('[data-testid="pr-list-loading"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pr-list-row-909"]').exists()).toBe(false)

    resolveList(
      makeListResponse([
        makeRow({ number: 909, head_ref: 'worktree/feat-x', title: 'On the board' }),
        makeRow({ number: 910, head_ref: 'worktree/elsewhere', title: 'Not on the board' }),
      ]),
    )
    await flushPromises()

    expect(wrapper.find('[data-testid="pr-list-loading"]').exists()).toBe(false)
    // Default filter is ON: only the matching row is visible.
    const row909 = wrapper.find('[data-testid="pr-list-row-909"]')
    expect(row909.exists()).toBe(true)
    expect(row909.text()).toContain('On the board')
    expect(row909.text()).toContain('Board card')
    expect(wrapper.find('[data-testid="pr-list-row-910"]').exists()).toBe(false)
    // …but turning the filter off reveals the off-board row with its
    // "no card" badge.
    await wrapper.find('[data-testid="pr-only-this-board"]').trigger('click')
    const row910 = wrapper.find('[data-testid="pr-list-row-910"]')
    expect(row910.exists()).toBe(true)
    expect(row910.text()).toContain('no card on this board')
    wrapper.unmount()
  })

  it('renders the empty state (not the error) on 200 with zero changes', async () => {
    const wrapper = mountList({ rows: [] })
    await flushPromises()
    expect(wrapper.find('[data-testid="pr-list-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pr-list-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="pr-list-empty"]').text()).toContain('The forge answered')
    wrapper.unmount()
  })

  it('renders the error state (not the empty state) when the forge call rejects', async () => {
    listPrsMock.mockRejectedValue(
      new ApiError(502, 'Bad Gateway', JSON.stringify({ error: 'gh exited 1: auth failed' })),
    )
    const wrapper = mountList()
    await flushPromises()
    const err = wrapper.find('[data-testid="pr-list-error"]')
    expect(err.exists()).toBe(true)
    expect(err.text()).toContain('could not be asked')
    expect(err.text()).toContain('gh exited 1: auth failed')
    expect(wrapper.find('[data-testid="pr-list-empty"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="pr-list-loading"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('close asks for confirm naming number+branch, then removes the row and emits closed', async () => {
    let resolveClose!: (v: unknown) => void
    closePrMock.mockReturnValue(
      new Promise((resolve) => {
        resolveClose = resolve
      }),
    )
    const wrapper = mountList({
      rows: [
        makeRow({ number: 909, head_ref: 'worktree/feat-x', title: 'Close me' }),
        makeRow({ number: 910, head_ref: 'worktree/other', title: 'Other' }),
      ],
      tasks: [],
    })
    await flushPromises()
    // Filter off so both rows are visible.
    await wrapper.find('[data-testid="pr-only-this-board"]').trigger('click')

    await closeButtonIn(wrapper, 'pr-list-row-909').trigger('click')
    expect(wrapper.find('[data-testid="pr-close-confirm"]').exists()).toBe(true)
    const msg = wrapper.find('[data-testid="pr-close-confirm-message"]').text()
    expect(msg).toContain('#909')
    expect(msg).toContain('worktree/feat-x')

    await wrapper.find('[data-testid="pr-close-confirm-yes"]').trigger('click')
    expect(closePrMock).toHaveBeenCalledWith('/repo', '909', { provider: 'github' })
    // While the close is in flight every other row's Close is disabled.
    expect(closeButtonIn(wrapper, 'pr-list-row-910').attributes('disabled')).toBeDefined()

    resolveClose({ closed: true, detail: '', provider: 'github', status: {} })
    await flushPromises()

    expect(wrapper.find('[data-testid="pr-list-row-909"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="pr-list-row-910"]').exists()).toBe(true)
    expect(wrapper.emitted('closed')).toEqual([[{ number: 909, headRef: 'worktree/feat-x' }]])
    expect(wrapper.find('[data-testid="pr-close-toast"]').text()).toContain('Closed #909')
    wrapper.unmount()
  })

  it('a close that resolves closed:false keeps the row and renders the forge sentence', async () => {
    closePrMock.mockResolvedValue({
      closed: false,
      detail: 'the forge left it open: review required',
      provider: 'github',
      status: {},
    })
    const wrapper = mountList({ rows: [makeRow({ number: 909 })] })
    await flushPromises()

    await closeButtonIn(wrapper, 'pr-list-row-909').trigger('click')
    await wrapper.find('[data-testid="pr-close-confirm-yes"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="pr-list-row-909"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pr-close-detail-909"]').text()).toContain(
      'the forge left it open: review required',
    )
    expect(wrapper.emitted('closed')).toBeUndefined()
    expect(wrapper.find('[data-testid="pr-close-toast"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('Only-this-board is on by default, hides off-board rows, and states the count', async () => {
    const wrapper = mountList({
      rows: [
        makeRow({ number: 909, head_ref: 'worktree/feat-x' }),
        makeRow({ number: 910, head_ref: 'worktree/elsewhere' }),
      ],
      tasks: [makeTask({ git_branch: 'worktree/feat-x' })],
    })
    await flushPromises()
    const pill = wrapper.find('[data-testid="pr-only-this-board"]')
    expect(pill.attributes('aria-pressed')).toBe('true')
    expect(pill.text()).toContain('1 of 2')
    expect(wrapper.find('[data-testid="pr-list-row-909"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pr-list-row-910"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('tab switches refetch only via the exposed reload (no prop watcher)', async () => {
    const wrapper = mountList({ rows: [makeRow({ number: 909 })] })
    await flushPromises()
    expect(listPrsMock).toHaveBeenCalledTimes(1)
    expect(listPrsMock).toHaveBeenLastCalledWith('/repo', { state: 'open', limit: 30 })

    // A tab prop change alone refetches nothing — the parent owns
    // the tab and calls reload() explicitly (local/no-watch).
    await wrapper.setProps({ tab: 'closed' })
    await flushPromises()
    expect(listPrsMock).toHaveBeenCalledTimes(1)

    listPrsMock.mockResolvedValue(makeListResponse([makeRow({ number: 911, state: 'closed' })]))
    ;(wrapper.vm as unknown as { reload: () => void }).reload()
    await flushPromises()
    expect(listPrsMock).toHaveBeenCalledTimes(2)
    expect(listPrsMock).toHaveBeenLastCalledWith('/repo', { state: 'closed', limit: 30 })
    expect(wrapper.find('[data-testid="pr-list-row-911"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

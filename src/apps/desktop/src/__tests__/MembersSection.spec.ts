import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'

import { ApiError, type WorkspaceInvitation, type WorkspaceMember } from '../api'
import * as api from '../api'
import MembersSection from '../components/workspace/MembersSection.vue'
import { useInvitationsStore } from '../stores/invitations'
import { makeLocalStorageStub } from './helpers'

// Only the members + invitations calls are stubbed; everything else stays real.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listMembers: vi.fn(),
    updateMemberRole: vi.fn(),
    removeMember: vi.fn(),
    listWorkspaceInvitations: vi.fn(),
    createInvitation: vi.fn(),
    revokeInvitation: vi.fn(),
    listMyInvitations: vi.fn(),
    acceptInvitation: vi.fn(),
    declineInvitation: vi.fn(),
  }
})

const mockList = api.listMembers as unknown as ReturnType<typeof vi.fn>
const mockUpdate = api.updateMemberRole as unknown as ReturnType<typeof vi.fn>
const mockRemove = api.removeMember as unknown as ReturnType<typeof vi.fn>
const mockPending = api.listWorkspaceInvitations as unknown as ReturnType<typeof vi.fn>
const mockInvite = api.createInvitation as unknown as ReturnType<typeof vi.fn>
const mockRevoke = api.revokeInvitation as unknown as ReturnType<typeof vi.fn>
const mockMine = api.listMyInvitations as unknown as ReturnType<typeof vi.fn>
const mockAccept = api.acceptInvitation as unknown as ReturnType<typeof vi.fn>
const mockDecline = api.declineInvitation as unknown as ReturnType<typeof vi.fn>

const owner: WorkspaceMember = {
  workspace_id: 'ws_1',
  user_id: 'user_amy',
  email: 'amy@example.com',
  name: 'Amy',
  role: 'owner',
  joined_at: '2026-10-01 09:00:00',
  invited_by: '',
}

const viewer: WorkspaceMember = {
  workspace_id: 'ws_1',
  user_id: 'user_ben',
  email: 'ben@example.com',
  name: '',
  role: 'viewer',
  joined_at: '2026-10-02 09:00:00',
  invited_by: 'user_amy',
}

const pendingInvite: WorkspaceInvitation = {
  id: 'inv_1',
  workspace_id: 'ws_1',
  workspace_name: 'Acme',
  invitee_user_id: 'user_cid',
  invitee_email: 'cid@example.com',
  invitee_name: '',
  role: 'editor',
  invited_by: 'user_amy',
  created_at: '2026-10-03 09:00:00',
}

function seed(members: WorkspaceMember[], pending: WorkspaceInvitation[] = []): void {
  mockList.mockResolvedValue({ members, count: members.length })
  mockPending.mockResolvedValue({ invitations: pending, count: pending.length })
}

async function mountSection(workspaceId = 'ws_1') {
  const wrapper = mount(MembersSection, { props: { workspaceId } })
  await flushPromises()
  return wrapper
}

function buttonsInDom(): HTMLButtonElement[] {
  return Array.from(document.body.querySelectorAll('button'))
}

function buttonByText(re: RegExp): HTMLButtonElement | undefined {
  return buttonsInDom().find((b) => re.test(b.textContent ?? ''))
}

describe('MembersSection', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    for (const mock of [mockList, mockUpdate, mockRemove, mockPending, mockInvite, mockRevoke, mockMine, mockAccept, mockDecline]) {
      mock.mockReset()
    }
    mockMine.mockResolvedValue({ invitations: [], count: 0 })
    seed([owner, viewer])
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('fetches the members and the pending invitations of the workspace it was handed', async () => {
    const wrapper = await mountSection('ws_42')

    expect(mockList).toHaveBeenCalledWith('ws_42')
    expect(mockPending).toHaveBeenCalledWith('ws_42')
    const rows = wrapper.findAll('[data-testid="member-row"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]?.text()).toContain('Amy')
    expect(rows[1]?.text()).toContain('ben@example.com')
    wrapper.unmount()
  })

  it('shows each member role in a select the caller can change', async () => {
    const wrapper = await mountSection()
    const selects = wrapper.findAll('[data-testid="member-role-select"]')

    expect(selects).toHaveLength(2)
    expect((selects[0]!.element as HTMLSelectElement).value).toBe('owner')
    expect((selects[1]!.element as HTMLSelectElement).value).toBe('viewer')

    await selects[1]?.setValue('editor')
    await flushPromises()

    expect(mockUpdate).toHaveBeenCalledWith('ws_1', 'user_ben', 'editor')
    wrapper.unmount()
  })

  it('puts the role select back when the server refuses the change', async () => {
    mockUpdate.mockRejectedValue(
      new ApiError(409, 'Conflict', '{"error":"a workspace must keep at least one owner"}'),
    )
    const wrapper = await mountSection()
    const select = wrapper.findAll('[data-testid="member-role-select"]')[0]!

    await select.setValue('viewer')
    await flushPromises()

    expect((select.element as HTMLSelectElement).value).toBe('owner')
    expect(wrapper.find('[data-testid="error-message"]').text()).toContain(
      'a workspace must keep at least one owner',
    )
    wrapper.unmount()
  })

  it('inviting creates a PENDING invitation and adds no member row', async () => {
    mockInvite.mockResolvedValue({ invitation: { ...pendingInvite } })
    const wrapper = await mountSection()

    await wrapper.find('[data-testid="invite-email-input"]').setValue('cid@example.com')
    await wrapper.find('[data-testid="invite-role-select"]').setValue('admin')
    await wrapper.find('[data-testid="invite-btn"]').trigger('click')
    await flushPromises()

    expect(mockInvite).toHaveBeenCalledWith('ws_1', 'cid@example.com', 'admin')
    // The whole point: no membership was created, so the member list is unchanged.
    expect(wrapper.findAll('[data-testid="member-row"]')).toHaveLength(2)
    // The pending list is re-read, which is where the new ask appears.
    expect(mockPending).toHaveBeenCalledTimes(2)
    expect((wrapper.find('[data-testid="invite-email-input"]').element as HTMLInputElement).value).toBe('')
    wrapper.unmount()
  })

  it('renders the pending invitations, and a revoke goes through the confirm', async () => {
    seed([owner], [pendingInvite])
    mockRevoke.mockResolvedValue({ success: true, id: 'inv_1' })
    const wrapper = await mountSection()

    const block = wrapper.find('[data-testid="pending-invitations"]')
    expect(block.exists()).toBe(true)
    expect(block.text()).toContain('cid@example.com')
    expect(block.text()).toContain('Pending invitations')

    await wrapper.find('[data-testid="revoke-btn"]').trigger('click')
    await flushPromises()
    expect(mockRevoke).not.toHaveBeenCalled()

    buttonByText(/^Revoke$/)!.click()
    await flushPromises()
    expect(mockRevoke).toHaveBeenCalledWith('ws_1', 'inv_1')
    wrapper.unmount()
  })

  it('renders no pending block when nothing is waiting', async () => {
    const wrapper = await mountSection()
    expect(wrapper.find('[data-testid="pending-invitations"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('surfaces the server refusal sentence for an address no account carries', async () => {
    mockInvite.mockRejectedValue(
      new ApiError(404, 'Not Found', '{"error":"no active account with the email \'ghost@example.com\'"}'),
    )
    const wrapper = await mountSection()

    await wrapper.find('[data-testid="invite-email-input"]').setValue('ghost@example.com')
    await wrapper.find('[data-testid="invite-btn"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="error-message"]').text()).toContain(
      "no active account with the email 'ghost@example.com'",
    )
    expect((wrapper.find('[data-testid="invite-email-input"]').element as HTMLInputElement).value).toBe(
      'ghost@example.com',
    )
    wrapper.unmount()
  })

  it('disables the invite button while the email is blank, and never calls the API', async () => {
    const wrapper = await mountSection()

    expect(wrapper.find('[data-testid="invite-btn"]').attributes('disabled')).toBeDefined()

    const input = wrapper.find('[data-testid="invite-email-input"]')
    await input.setValue('   ')
    await input.trigger('keyup.enter')
    await flushPromises()

    expect(mockInvite).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="invite-error"]').text()).toContain('email address')
    wrapper.unmount()
  })

  it('removes a member only after the confirmation', async () => {
    mockRemove.mockResolvedValue({ success: true, user_id: 'user_ben' })
    const wrapper = await mountSection()

    await wrapper.findAll('[data-testid="remove-btn"]')[1]?.trigger('click')
    await flushPromises()
    expect(mockRemove).not.toHaveBeenCalled()

    buttonByText(/^Remove$/)!.click()
    await flushPromises()
    expect(mockRemove).toHaveBeenCalledWith('ws_1', 'user_ben')
    wrapper.unmount()
  })

  it('disables removal of the only owner', async () => {
    seed([owner, viewer])
    const wrapper = await mountSection()

    const buttons = wrapper.findAll('[data-testid="remove-btn"]')
    expect(buttons[0]?.attributes('disabled')).toBeDefined()
    expect(buttons[0]?.attributes('title')).toContain('at least one owner')
    expect(buttons[1]?.attributes('disabled')).toBeUndefined()
    wrapper.unmount()

    setActivePinia(createPinia())
    mockMine.mockResolvedValue({ invitations: [], count: 0 })
    seed([owner, { ...viewer, role: 'owner' }])
    const second = await mountSection()
    expect(second.findAll('[data-testid="remove-btn"]')[0]?.attributes('disabled')).toBeUndefined()
    second.unmount()
  })

  it('an editor reads the roster read-only, and a 403 is a note rather than an error', async () => {
    mockPending.mockRejectedValue(
      new ApiError(403, 'Forbidden', '{"error":"Only a workspace owner or admin can do that"}'),
    )
    const wrapper = await mountSection()

    // The roster itself is readable by any member.
    expect(wrapper.findAll('[data-testid="member-row"]')).toHaveLength(2)
    // But a permission they do not have is not a broken request.
    expect(wrapper.find('[data-testid="error-message"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="read-only-note"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="invite-email-input"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="member-role-select"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="remove-btn"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('renders a failed load as an error with a retry, never as an empty workspace', async () => {
    mockList.mockRejectedValue(new ApiError(500, 'Internal Server Error', ''))
    const wrapper = await mountSection()

    expect(wrapper.find('[data-testid="error-message"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="member-row"]').exists()).toBe(false)

    await wrapper.find('[data-testid="retry-btn"]').trigger('click')
    await flushPromises()
    expect(mockList).toHaveBeenCalledTimes(2)
    wrapper.unmount()
  })

  it('renders the empty state only once a list has actually loaded', async () => {
    seed([])
    const pending = mount(MembersSection, { props: { workspaceId: 'ws_1' } })
    expect(pending.find('[data-testid="empty-state"]').exists()).toBe(false)
    await flushPromises()
    expect(pending.find('[data-testid="empty-state"]').exists()).toBe(true)
    pending.unmount()
  })
})

describe('useInvitationsStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    for (const mock of [mockMine, mockAccept, mockDecline, mockInvite, mockRevoke, mockPending]) {
      mock.mockReset()
    }
    mockMine.mockResolvedValue({ invitations: [pendingInvite], count: 1 })
  })

  it('fills the inbox from the server, and records a failure instead of blanking it', async () => {
    const store = useInvitationsStore()

    await store.fetchMine()
    expect(store.mine.map((i) => i.id)).toEqual(['inv_1'])
    expect(store.loaded).toBe(true)

    mockMine.mockRejectedValue(new ApiError(500, 'Internal Server Error', ''))
    await store.fetchMine()
    expect(store.error).not.toBeNull()
  })

  it('accept returns the workspace id that is now available, and re-reads the inbox', async () => {
    mockAccept.mockResolvedValue({ member: { workspace_id: 'ws_1', user_id: 'user_ben', role: 'editor' } })
    const store = useInvitationsStore()
    await store.fetchMine()

    const workspaceId = await store.accept('inv_1')

    expect(workspaceId).toBe('ws_1')
    expect(mockAccept).toHaveBeenCalledWith('inv_1')
    expect(mockMine).toHaveBeenCalledTimes(2)
  })

  it('a refused accept reports why and hands back no workspace', async () => {
    mockAccept.mockRejectedValue(
      new ApiError(404, 'Not Found', '{"error":"Invitation not found"}'),
    )
    const store = useInvitationsStore()

    expect(await store.accept('inv_1')).toBeNull()
    expect(store.error).toContain('Invitation not found')
  })

  it('decline asks the server and refreshes the inbox', async () => {
    mockDecline.mockResolvedValue({ success: true, id: 'inv_1' })
    const store = useInvitationsStore()

    expect(await store.decline('inv_1')).toBe(true)
    expect(mockDecline).toHaveBeenCalledWith('inv_1')
    expect(mockMine).toHaveBeenCalledTimes(1)
  })

  it('invite refreshes the workspace pending list and keeps the error on a refusal', async () => {
    mockInvite.mockResolvedValue({ invitation: pendingInvite })
    mockPending.mockResolvedValue({ invitations: [pendingInvite], count: 1 })
    const store = useInvitationsStore()

    expect(await store.invite('ws_1', 'cid@example.com', 'editor')).toBe(true)
    expect(store.pending).toHaveLength(1)

    mockInvite.mockRejectedValue(
      new ApiError(409, 'Conflict', '{"error":"that account already has a pending invitation to this workspace"}'),
    )
    expect(await store.invite('ws_1', 'cid@example.com', 'editor')).toBe(false)
    expect(store.error).toContain('already has a pending invitation')
  })
})

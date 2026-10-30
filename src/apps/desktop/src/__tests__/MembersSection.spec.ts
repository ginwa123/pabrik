import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'

import { ApiError, type WorkspaceMember } from '../api'
import * as api from '../api'
import MembersSection from '../components/workspace/MembersSection.vue'
import { useMembersStore } from '../stores/members'
import { makeLocalStorageStub } from './helpers'

// Only the four members calls are stubbed; everything else stays real.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listMembers: vi.fn(),
    inviteMember: vi.fn(),
    updateMemberRole: vi.fn(),
    removeMember: vi.fn(),
  }
})

const mockList = api.listMembers as unknown as ReturnType<typeof vi.fn>
const mockInvite = api.inviteMember as unknown as ReturnType<typeof vi.fn>
const mockUpdate = api.updateMemberRole as unknown as ReturnType<typeof vi.fn>
const mockRemove = api.removeMember as unknown as ReturnType<typeof vi.fn>

const owner: WorkspaceMember = {
  user_id: 'user_amy',
  email: 'amy@example.com',
  name: 'Amy',
  role: 'owner',
  joined_at: '2026-10-01 09:00:00',
  invited_by: '',
}

const viewer: WorkspaceMember = {
  user_id: 'user_ben',
  email: 'ben@example.com',
  name: '',
  role: 'viewer',
  joined_at: '2026-10-02 09:00:00',
  invited_by: 'user_amy',
}

function seedList(members: WorkspaceMember[]): void {
  mockList.mockResolvedValue({ members, count: members.length })
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
    for (const mock of [mockList, mockInvite, mockUpdate, mockRemove]) mock.mockReset()
    seedList([owner, viewer])
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

  it('fetches the members of the workspace it was handed and renders one row per member', async () => {
    const wrapper = await mountSection('ws_42')

    expect(mockList).toHaveBeenCalledWith('ws_42')
    const rows = wrapper.findAll('[data-testid="member-row"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]?.text()).toContain('Amy')
    expect(rows[0]?.text()).toContain('amy@example.com')
    // A member with no name is identified by the email, not by a blank row.
    expect(rows[1]?.text()).toContain('ben@example.com')
    expect(rows[0]?.find('[data-testid="member-email"]').text()).toBe('amy@example.com')
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
    mockUpdate.mockRejectedValue(new ApiError(409, 'Conflict', '{"error":"a workspace must keep at least one owner"}'))
    const wrapper = await mountSection()
    const select = wrapper.findAll('[data-testid="member-role-select"]')[0]!

    await select.setValue('viewer')
    await flushPromises()

    // The server never accepted it, so the control must not show it.
    expect((select.element as HTMLSelectElement).value).toBe('owner')
    expect(wrapper.find('[data-testid="error-message"]').text()).toContain(
      'a workspace must keep at least one owner',
    )
    wrapper.unmount()
  })

  it('invites the typed email with the chosen role, then clears the form', async () => {
    mockInvite.mockResolvedValue({ member: { ...viewer, user_id: 'user_cid', email: 'cid@example.com' } })
    const wrapper = await mountSection()

    await wrapper.find('[data-testid="invite-email-input"]').setValue('cid@example.com')
    await wrapper.find('[data-testid="invite-role-select"]').setValue('admin')
    await wrapper.find('[data-testid="invite-btn"]').trigger('click')
    await flushPromises()

    expect(mockInvite).toHaveBeenCalledWith('ws_1', 'cid@example.com', 'admin')
    expect((wrapper.find('[data-testid="invite-email-input"]').element as HTMLInputElement).value).toBe('')
    expect((wrapper.find('[data-testid="invite-role-select"]').element as HTMLSelectElement).value).toBe(
      'viewer',
    )
    // Every write refetches, so the list is the server's, not an optimistic guess.
    expect(mockList).toHaveBeenCalledTimes(2)
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

    // `HTTP 404 Not Found` tells the user nothing; the server's sentence does.
    expect(wrapper.find('[data-testid="error-message"]').text()).toContain(
      "no active account with the email 'ghost@example.com'",
    )
    // The typed address stays put so it can be corrected.
    expect((wrapper.find('[data-testid="invite-email-input"]').element as HTMLInputElement).value).toBe(
      'ghost@example.com',
    )
    wrapper.unmount()
  })

  it('disables the invite button while the email is blank, and never calls the API', async () => {
    const wrapper = await mountSection()

    expect(wrapper.find('[data-testid="invite-btn"]').attributes('disabled')).toBeDefined()

    // Enter bypasses the disabled button, so the form validates on the way in
    // rather than sending a request that could only be refused.
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
    expect(document.body.querySelector('.fixed.inset-0')).not.toBeNull()

    buttonByText(/^Remove$/)!.click()
    await flushPromises()
    expect(mockRemove).toHaveBeenCalledWith('ws_1', 'user_ben')
    wrapper.unmount()
  })

  it('disables removal of the only owner', async () => {
    seedList([owner, viewer])
    const wrapper = await mountSection()

    const buttons = wrapper.findAll('[data-testid="remove-btn"]')
    expect(buttons[0]?.attributes('disabled')).toBeDefined()
    expect(buttons[0]?.attributes('title')).toContain('at least one owner')
    expect(buttons[1]?.attributes('disabled')).toBeUndefined()
    wrapper.unmount()

    // With a second owner there is nothing to protect.
    setActivePinia(createPinia())
    seedList([owner, { ...viewer, role: 'owner' }])
    const second = await mountSection()
    expect(second.findAll('[data-testid="remove-btn"]')[0]?.attributes('disabled')).toBeUndefined()
    second.unmount()
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
    seedList([])
    // Still in flight: an empty state here would claim the server said "none".
    const pending = mount(MembersSection, { props: { workspaceId: 'ws_1' } })
    expect(pending.find('[data-testid="empty-state"]').exists()).toBe(false)
    await flushPromises()
    expect(pending.find('[data-testid="empty-state"]').exists()).toBe(true)
    pending.unmount()
  })

  it('is driven by the store, so a second mount for another workspace has no stale rows', async () => {
    const first = await mountSection('ws_1')
    expect(first.findAll('[data-testid="member-row"]')).toHaveLength(2)
    first.unmount()

    seedList([owner])
    const second = await mountSection('ws_2')
    expect(second.findAll('[data-testid="member-row"]')).toHaveLength(1)
    expect(mockList).toHaveBeenLastCalledWith('ws_2')
    second.unmount()
  })
})

describe('useMembersStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    for (const mock of [mockList, mockInvite, mockUpdate, mockRemove]) mock.mockReset()
    seedList([owner])
  })

  it('records a failed fetch in error and leaves loaded false', async () => {
    mockList.mockRejectedValue(new ApiError(403, 'Forbidden', '{"error":"Only a workspace owner or admin can do that"}'))
    const store = useMembersStore()

    await store.fetchMembers('ws_1')

    expect(store.loaded).toBe(false)
    expect(store.members).toHaveLength(0)
    expect(store.error).toContain('Only a workspace owner or admin can do that')
  })

  it('refetches after a successful invite so the list stays the server list', async () => {
    mockInvite.mockResolvedValue({ member: viewer })
    const store = useMembersStore()

    await store.fetchMembers('ws_1')
    seedList([owner, viewer])
    const ok = await store.inviteMember('ws_1', 'ben@example.com', 'viewer')

    expect(ok).toBe(true)
    expect(store.members.map((m) => m.user_id)).toEqual(['user_amy', 'user_ben'])
    expect(mockList).toHaveBeenCalledTimes(2)
  })

  it('keeps the previous list when an invite fails, and reports why', async () => {
    mockInvite.mockRejectedValue(new ApiError(409, 'Conflict', '{"error":"that account is already a member of this workspace"}'))
    const store = useMembersStore()

    await store.fetchMembers('ws_1')
    const ok = await store.inviteMember('ws_1', 'amy@example.com', 'viewer')

    expect(ok).toBe(false)
    expect(store.members).toHaveLength(1)
    expect(store.error).toContain('that account is already a member of this workspace')
  })

  it('reset forgets the list and the error, so a workspace switch starts clean', async () => {
    mockList.mockRejectedValue(new ApiError(500, 'Internal Server Error', ''))
    const store = useMembersStore()
    await store.fetchMembers('ws_1')
    expect(store.error).not.toBeNull()

    store.reset()

    expect(store.error).toBeNull()
    expect(store.loaded).toBe(false)
    expect(store.members).toHaveLength(0)
  })
})

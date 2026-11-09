import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'

import { useChatGroupRoster } from '../components/views/chat_view/useChatGroupRoster'
import ChatGroupRoster from '../components/views/chat_view/ChatGroupRoster.vue'
import { ApiError, type GroupMember, type SessionGroup } from '../api'

const getSessionGroup = vi.hoisted(() => vi.fn())
const addSessionGroupMember = vi.hoisted(() => vi.fn())
const removeSessionGroupMember = vi.hoisted(() => vi.fn())
const setSessionGroupLead = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    getSessionGroup,
    addSessionGroupMember,
    removeSessionGroupMember,
    setSessionGroupLead,
  }
})

const rosterOf = (members: GroupMember[], lead = ''): SessionGroup => ({
  session_id: 's_1',
  group: lead.length > 0,
  lead,
  members,
})

const fakeServer = () => {
  let members: GroupMember[] = []
  let lead = ''
  const snapshot = (): SessionGroup => rosterOf(members.map((m) => ({ ...m })), lead)
  return {
    get: () => Promise.resolve(snapshot()),
    add: (_sessionId: string, agent: string) => {
      if (!members.some((m) => m.name === agent)) members = [...members, { name: agent, role: 'worker' }]
      if (lead.length === 0) lead = agent
      members = members.map((m) => ({ ...m, role: m.name === lead ? 'lead' : 'worker' }))
      return Promise.resolve(snapshot())
    },
    remove: (_sessionId: string, agent: string) => {
      members = members.filter((m) => m.name !== agent)
      if (members.length === 0) lead = ''
      return Promise.resolve(snapshot())
    },
    lead: (_sessionId: string, agent: string) => {
      lead = agent
      members = members.map((m) => ({ ...m, role: m.name === lead ? 'lead' : 'worker' }))
      return Promise.resolve(snapshot())
    },
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('useChatGroupRoster', () => {
  it('reads the roster the server holds', async () => {
    getSessionGroup.mockResolvedValue(rosterOf([{ name: 'BEAM', role: 'lead' }], 'BEAM'))
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })

    await roster.load()

    expect(roster.memberNames.value).toEqual(['BEAM'])
    expect(roster.lead.value).toBe('BEAM')
    expect(roster.isGroup.value).toBe(true)
  })

  it('a chat with no members is not a group', async () => {
    getSessionGroup.mockResolvedValue(rosterOf([]))
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })

    await roster.load()

    expect(roster.isGroup.value).toBe(false)
    expect(roster.members.value).toEqual([])
  })

  it('adding an agent puts it in the roster and the first one leads', async () => {
    const server = fakeServer()
    getSessionGroup.mockImplementation(server.get)
    addSessionGroupMember.mockImplementation(server.add)
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })
    await roster.load()

    await roster.add('deepseek auto')

    expect(roster.memberNames.value).toEqual(['deepseek auto'])
    expect(roster.lead.value).toBe('deepseek auto')
  })

  it('removing the last agent stops the chat being a group', async () => {
    const server = fakeServer()
    getSessionGroup.mockImplementation(server.get)
    addSessionGroupMember.mockImplementation(server.add)
    removeSessionGroupMember.mockImplementation(server.remove)
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })
    await roster.load()
    await roster.add('BEAM')

    await roster.remove('BEAM')

    expect(roster.members.value).toEqual([])
    expect(roster.isGroup.value).toBe(false)
  })

  it('handing the lead to another member moves it', async () => {
    const server = fakeServer()
    getSessionGroup.mockImplementation(server.get)
    addSessionGroupMember.mockImplementation(server.add)
    setSessionGroupLead.mockImplementation(server.lead)
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })
    await roster.load()
    await roster.add('BEAM')
    await roster.add('deepseek auto')

    await roster.makeLead('deepseek auto')

    expect(roster.lead.value).toBe('deepseek auto')
    expect(roster.members.value.find((m) => m.name === 'BEAM')?.role).toBe('worker')
  })

  it('a rejected request surfaces the reason and leaves the roster alone', async () => {
    getSessionGroup.mockResolvedValue(rosterOf([{ name: 'BEAM', role: 'lead' }], 'BEAM'))
    addSessionGroupMember.mockRejectedValue(new Error('agent is not a member of this chat'))
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })
    await roster.load()

    await roster.add('ghost')

    expect(roster.error.value).toBe('agent is not a member of this chat')
    expect(roster.memberNames.value).toEqual(['BEAM'])
  })

  it('a chat with no session id never asks the server', async () => {
    const roster = useChatGroupRoster({ sessionId: ref('') })

    await roster.load()

    expect(getSessionGroup).not.toHaveBeenCalled()
    expect(roster.members.value).toEqual([])
  })

  it('a session that does not exist yet has no roster and no error', async () => {
    getSessionGroup.mockRejectedValue(
      new ApiError(404, 'Not Found', JSON.stringify({ error: 'Session not found' })),
    )
    const roster = useChatGroupRoster({ sessionId: ref('s_gone') })

    await roster.load()

    expect(roster.members.value).toEqual([])
    expect(roster.isGroup.value).toBe(false)
    expect(roster.error.value).toBeNull()
  })

  it('a server failure still surfaces the reason', async () => {
    getSessionGroup.mockRejectedValue(new ApiError(500, 'Internal Server Error', 'boom'))
    const roster = useChatGroupRoster({ sessionId: ref('s_1') })

    await roster.load()

    expect(roster.error.value).toBe('HTTP 500 Internal Server Error')
  })
})

describe('ChatGroupRoster', () => {
  const agents = [{ name: 'BEAM' }, { name: 'deepseek auto' }]

  const mountRoster = (overrides: Record<string, unknown> = {}) =>
    mount(ChatGroupRoster, {
      props: {
        members: [{ name: 'BEAM', role: 'lead' }] as GroupMember[],
        lead: 'BEAM',
        isGroup: true,
        isBusy: false,
        error: null,
        agents,
        ownAgent: 'BEAM',
        ...overrides,
      },
    })

  it('the toggle counts the agents in the chat', () => {
    const wrapper = mountRoster()

    expect(wrapper.get('[data-testid="chat-group-roster-count"]').text()).toBe('1')
  })

  it('the panel names the chat\'s own agent, not just the added ones', async () => {
    const wrapper = mountRoster({ members: [], lead: '', isGroup: false, ownAgent: 'deepseek auto' })

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')

    expect(wrapper.get('[data-testid="chat-group-own-agent"]').text()).toContain('deepseek auto')
    expect(wrapper.get('[data-testid="chat-group-own-agent-badge"]').text()).toBe('this chat')
  })

  it('opening the panel lists the members and marks the lead', async () => {
    const wrapper = mountRoster()

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')

    expect(wrapper.find('[data-testid="chat-group-member-BEAM"]').exists()).toBe(true)
    expect(wrapper.get('[data-testid="chat-group-lead-badge"]').text()).toBe('lead')
  })

  it('an agent outside the roster is offered for adding', async () => {
    const wrapper = mountRoster()

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')
    await wrapper.get('[data-testid="chat-group-add-deepseek auto"]').trigger('click')

    expect(wrapper.emitted('add')).toEqual([['deepseek auto']])
  })

  it('a member already in the roster is not offered for adding', async () => {
    const wrapper = mountRoster()

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')

    expect(wrapper.find('[data-testid="chat-group-add-BEAM"]').exists()).toBe(false)
  })

  it('removing a member asks the chat to drop it', async () => {
    const wrapper = mountRoster()

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')
    await wrapper.get('[data-testid="chat-group-remove-BEAM"]').trigger('click')

    expect(wrapper.emitted('remove')).toEqual([['BEAM']])
  })

  it('a worker can be made the lead', async () => {
    const wrapper = mountRoster({
      members: [
        { name: 'BEAM', role: 'lead' },
        { name: 'deepseek auto', role: 'worker' },
      ] as GroupMember[],
    })

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')
    await wrapper.get('[data-testid="chat-group-make-lead-deepseek auto"]').trigger('click')

    expect(wrapper.emitted('make-lead')).toEqual([['deepseek auto']])
  })

  it('an empty chat says how to start one', async () => {
    const wrapper = mountRoster({ members: [], lead: '', isGroup: false })

    await wrapper.get('[data-testid="chat-group-roster-toggle"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="chat-group-roster-empty"]').exists()).toBe(true)
  })
})

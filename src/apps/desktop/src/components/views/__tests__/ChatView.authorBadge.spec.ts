/** The author badge on a reply (PR #1168's `.msg-author`): a group thread names
 * every reply, and a one-agent chat takes the session's agent — the name the
 * composer chip shows. The presenter decides both, so both are asserted here. */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { ref } from 'vue'
import {
  PLACEHOLDER_AGENT,
  useChatMessagePresentation,
  type Message,
  type MessageGroup,
} from '../chat_view/useChatMessagePresentation'

const CHAT_VIEW = path.resolve(__dirname, '..', 'chat_view')

function msg(over: Partial<Message> & { id: string; role: Message['role'] }): Message {
  return { content: 'an answer', timestamp: new Date(1_000), ...over }
}

const assistant = (over: Partial<Message> & { id: string }): Message =>
  msg({ role: 'assistant', ...over })

const user = (id: string): Message => msg({ id, role: 'user' })

function groupsFor(messages: Message[], authorLabel?: () => string): MessageGroup[] {
  const messagesRef = ref<Message[]>([])
  const { messageGroups } = useChatMessagePresentation({
    messages: messagesRef,
    expandedToolIds: ref(new Set<string>()),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- only read by the tool cards
    subAgentProgressMap: ref({}) as any,
    isPendingSession: ref(false),
    sessionId: ref('sess_1'),
    isRemoteLoadPending: ref(false),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- the label logic never reads the mode
    mode: () => 'comfortable' as any,
    authorLabel,
  })
  // The component's first render is an empty transcript, and that pass is what
  // resolves the `messageGroups` ↔ `groupToolNames` cycle. Mirror it here.
  void messageGroups.value
  messagesRef.value = messages
  return messageGroups.value
}

const authors = (groups: MessageGroup[]): (string | undefined)[] =>
  groups.filter((g) => g.role === 'assistant').map((g) => g.author)

describe('the author badge on a reply', () => {
  it('a one-author chat is labelled with the session’s agent', () => {
    const groups = groupsFor(
      [user('u1'), assistant({ id: 'a1' }), assistant({ id: 'a2' })],
      () => 'deepseek auto',
    )

    expect(authors(groups)).toEqual(['deepseek auto']) // one block: consecutive replies from one agent
  })

  it('a shared thread names each block after its own author', () => {
    const groups = groupsFor(
      [
        user('u1'),
        assistant({ id: 'a1', agent_name: 'BEAM' }),
        assistant({ id: 'a2', agent_name: 'BEAM Reviewer' }),
        assistant({ id: 'a3', agent_name: 'BEAM' }),
      ],
      () => 'deepseek auto',
    )

    expect(authors(groups)).toEqual(['BEAM', 'BEAM Reviewer', 'BEAM'])
  })

  it('a different author splits the block even when the role matches', () => {
    const groups = groupsFor([
      user('u1'),
      assistant({ id: 'a1', agent_name: 'BEAM' }),
      assistant({ id: 'a2', agent_name: 'BEAM Reviewer' }),
    ])

    expect(authors(groups)).toHaveLength(2)
  })

  it('the placeholder column default never becomes a badge', () => {
    expect(PLACEHOLDER_AGENT).toBe('Agent')
    const groups = groupsFor(
      [user('u1'), assistant({ id: 'a1', agent_name: 'Agent' })],
      () => 'deepseek auto',
    )

    expect(authors(groups)).toEqual(['deepseek auto'])
  })

  it('one known author in a shared thread outranks the session label', () => {
    const groups = groupsFor(
      [user('u1'), assistant({ id: 'a1', agent_name: 'implementator' })],
      () => 'deepseek auto',
    )

    expect(authors(groups)).toEqual(['implementator'])
  })

  it('without a session label the transcript stays anonymous, as before', () => {
    const groups = groupsFor([user('u1'), assistant({ id: 'a1' })])

    expect(authors(groups)).toEqual([undefined])
  })

  it('an empty label is not a badge', () => {
    const groups = groupsFor([user('u1'), assistant({ id: 'a1' })], () => '   ')

    expect(authors(groups)).toEqual([undefined])
  })

  it('a user turn is never labelled', () => {
    const groups = groupsFor([user('u1')], () => 'deepseek auto')

    expect(groups.filter((g) => g.role === 'user')[0]?.author).toBeUndefined()
  })
})

describe('the live SSE path keeps the author the backend sends', () => {
  const source = readFileSync(path.join(CHAT_VIEW, 'useChatSse.ts'), 'utf8')

  it('attributes the pushed full row', () => {
    expect(source).toMatch(/agent_name: event\.agent_name \|\| undefined/)
  })

  it('attributes the cached row, which is read back through `agent`', () => {
    expect(source).toMatch(/agent: event\.agent_name/)
  })

  it('attributes an in-place update of a row that is already rendered', () => {
    expect(source).toMatch(/existingById\.agent_name = event\.agent_name/)
  })
})

describe('the badge markup reads the presenter’s decision', () => {
  const template = readFileSync(path.join(CHAT_VIEW, 'ChatMessageRow.vue'), 'utf8')

  it('renders only when the group carries an author', () => {
    expect(template).toMatch(/v-if="group\.role === 'assistant' && group\.author"/)
    expect(template).toMatch(/class="msg-author"/)
  })
})

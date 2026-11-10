/** A background-command completion is a TOOL result the backend stores as `role=user` (the loop
 * feeds it back to the model). It must group and fold with the calls — not sit in the transcript as
 * a user turn, and not split one agent run into three cards. */
import { describe, it, expect } from 'vitest'
import { ref } from 'vue'
import {
  useChatMessagePresentation,
  type Message,
  type MessageGroup,
} from '../chat_view/useChatMessagePresentation'

const BG_COMMAND = 'zig build functional-test:zig'

/** The envelope the background-process watcher inserts when a detached `command` finishes. */
const BACKGROUND_COMPLETION = JSON.stringify({
  pid: 4242,
  command: BG_COMMAND,
  stdout: 'ok',
  truncated: false,
  log_path: null,
})

const at = (second: number): Date => new Date(1_700_000_000_000 + second * 1000)

const user = (id: string, content: string, second: number): Message => ({
  id,
  role: 'user',
  content,
  timestamp: at(second),
})

const assistant = (
  id: string,
  content: string,
  finishReason: string,
  second: number,
  toolCallId?: string,
): Message => ({
  id,
  role: 'assistant',
  content,
  finish_reason: finishReason,
  timestamp: at(second),
  tool_calls_json: toolCallId
    ? JSON.stringify([
        {
          id: toolCallId,
          type: 'function',
          function: { name: 'command', arguments: JSON.stringify({ command: 'ls' }) },
        },
      ])
    : '[]',
})

const toolResult = (id: string, toolCallId: string, second: number): Message => ({
  id,
  role: 'tool',
  content: JSON.stringify({
    tool: 'command',
    parameters: { command: 'ls' },
    success: true,
    data: { command: 'ls', stdout: 'a.ts', stderr: '', exit_code: 0 },
    error: null,
    v: 1,
  }),
  tool_call_id: toolCallId,
  tool_name: 'command',
  timestamp: at(second),
})

/** One agent turn: call, result, a background completion, call, result, then the answer. */
const TURN: Message[] = [
  user('u1', 'run the suite', 0),
  assistant('a1', '', 'tool_calls', 1, 'tc1'),
  toolResult('t1', 'tc1', 2),
  user('bg1', BACKGROUND_COMPLETION, 3),
  assistant('a2', '', 'tool_calls', 4, 'tc2'),
  toolResult('t2', 'tc2', 5),
  assistant('a3', 'Done.', 'stop', 6),
]

function presentation(messages: Message[], mode: 'dev' | 'compact' = 'compact') {
  const messagesRef = ref<Message[]>([])
  const p = useChatMessagePresentation({
    messages: messagesRef,
    expandedToolIds: ref(new Set<string>()),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- only read by the tool cards
    subAgentProgressMap: ref({}) as any,
    isPendingSession: ref(false),
    sessionId: ref('sess_1'),
    isRemoteLoadPending: ref(false),
    mode: () => mode,
  })
  // The component's first render is an empty transcript, and that pass is what resolves the
  // `messageGroups` ↔ `groupToolNames` cycle. Mirror it here.
  void p.messageGroups.value
  messagesRef.value = messages
  return p
}

const roles = (groups: MessageGroup[]): string[] => groups.map((g) => g.role)

describe('a background-command completion is a tool row', () => {
  it('groups with the calls instead of standing in as a user turn', () => {
    const { messageGroups } = presentation(TURN)

    expect(roles(messageGroups.value)).toEqual([
      'user',
      'assistant',
      'tool',
      'assistant',
      'tool',
      'assistant',
    ])
    const carriers = messageGroups.value.filter((g) => g.messages.some((m) => m.id === 'bg1'))
    expect(carriers).toHaveLength(1)
    expect(carriers[0]!.role).toBe('tool')
  })

  it('does not split the run: one chain holds every call of the turn', () => {
    const { compactChains } = presentation(TURN)

    expect(compactChains.value.size).toBe(1)
    const items = [...compactChains.value.values()][0]!
    const calls = items.filter((item) => item.kind === 'tool')
    expect(calls).toHaveLength(3)
  })

  it('draws the completion as the command it ran', () => {
    const { compactChains } = presentation(TURN)

    const items = [...compactChains.value.values()][0]!
    const background = items.find((item) => item.kind === 'tool' && item.card.message.id === 'bg1')
    expect(background).toBeDefined()
    if (background?.kind !== 'tool') throw new Error('unreachable')
    expect(background.card.message.tool_name).toBe('command')
    expect(background.card.parameters).toContain(BG_COMMAND)
    expect(background.card.content).toMatchObject({ command: BG_COMMAND, stdout: 'ok' })
  })

  it('earns no rail pill — it is not a turn to jump to', () => {
    const { userPills } = presentation(TURN)

    expect(userPills.value).toHaveLength(1)
    expect(userPills.value[0]!.preview).toBe('run the suite')
  })

  it('the dev view draws it through the same shell card as any command', () => {
    const { messageGroups, toolCardsFor } = presentation(TURN, 'dev')

    const index = messageGroups.value.findIndex((g) => g.messages.some((m) => m.id === 'bg1'))
    const group = messageGroups.value[index]!
    const card = toolCardsFor(group, index).find((c) => c.message.id === 'bg1')
    expect(card?.message.tool_name).toBe('command')
    expect(card?.content).toMatchObject({ command: BG_COMMAND, stdout: 'ok' })
  })
})

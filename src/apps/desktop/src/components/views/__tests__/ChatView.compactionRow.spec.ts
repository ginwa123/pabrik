/** The turn sent straight after a compaction. */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref } from 'vue'
import ChatMessageRow from '../chat_view/ChatMessageRow.vue'
import {
  isCompactionMessage,
  useChatMessagePresentation,
  type Message,
  type MessageGroup,
} from '../chat_view/useChatMessagePresentation'
import type { SubAgentProgressMap } from '../../../helpers/subagentProgress'

const COMPACTION_ENVELOPE = JSON.stringify({
  compact_messages: {
    format_version: 2,
    metadata: { session_id: 'task_1', model: 'deepseek', compacted_at: '2026-11-15 13:30:57' },
    plan: { markdown: '## Goal\n- [x] wire it', updated_at: '2026-11-15 12:26:04' },
    message_index: [
      { id: 'adhoc_16', role: 'tool', preview: 'glyphs.zig', tool_call_id: 'call_00_pspev' },
      {
        id: 'adhoc_17',
        role: 'assistant',
        preview: 'cleared the paint buffer',
        tool_call_id: null,
      },
    ],
  },
})

let seq = 0
function msg(over: Partial<Message> & { role: Message['role'] }): Message {
  seq += 1
  return {
    id: `h_${seq}`,
    content: '',
    timestamp: new Date(1_000 * seq),
    ...over,
  }
}

/** The compaction row the backend wrote, and the human's next sentence. */
const afterCompaction = (): Message[] => [
  msg({ role: 'assistant', content: 'The compacted history is in place.' }),
  msg({ role: 'user', content: COMPACTION_ENVELOPE }),
  msg({ role: 'user', content: 'props data type don’t match — check the clay enum' }),
]

function presentationFor(messages: Message[]) {
  const messagesRef = ref<Message[]>([])
  const deps = useChatMessagePresentation({
    messages: messagesRef,
    expandedToolIds: ref(new Set<string>()),
    subAgentProgressMap: ref<SubAgentProgressMap>({}),
    isPendingSession: ref(false),
    sessionId: ref('task_1'),
    isRemoteLoadPending: ref(false),
    mode: () => 'compact',
  })
  // The first render is an empty transcript; that pass is what resolves the `messageGroups` ↔ `groupToolNames` cycle.
  void deps.messageGroups.value
  messagesRef.value = messages
  return deps
}

/** Mounts one `ChatMessageRow` per group — the transcript as the scroller draws it. */
function renderTranscript(groups: MessageGroup[]): string {
  const lastIndex = groups.length - 1
  return groups
    .map((group, groupIndex) => {
      const wrapper = mount(ChatMessageRow, {
        props: {
          group,
          groupIndex,
          mode: 'compact',
          sessionId: 'task_1',
          chatId: 'chat-task_1',
          cwd: '/repo',
          groupKey: (g: MessageGroup) => g.messages[0]?.id ?? 'empty',
          isLastGroup: (i: number) => i === lastIndex,
          hasBubbleContent: () => true,
          isCompactionMessage,
          openImagePreview: () => undefined,
          asked: null,
          compactChains: new Map(),
          standaloneCardsFor: () => [],
          toolCardsFor: () => [],
          toggleToolExpanded: () => undefined,
          openPeek: () => undefined,
          handleFallbackJumpToLine: () => undefined,
          onOpenWorkspaceSession: () => undefined,
          visibleReasoning: () => [],
          answeredMessages: (g: MessageGroup) => g.messages,
          hasVisibleContent: (m: Message) => (m.content ?? '').trim().length > 0,
          renderMessageHtml: (m: Message) => m.content,
        },
        global: {
          stubs: {
            MessageActions: true,
            SkillInvocationCard: true,
            ChatAttachments: true,
            MermaidDiagram: true,
            PlantUmlDiagram: true,
            D2Diagram: true,
            ToolCard: true,
            CompactToolGroup: true,
            AskUser: true,
          },
        },
      })
      const text = wrapper.text()
      wrapper.unmount()
      return text
    })
    .join('\n')
}

describe('the message sent right after a compaction', () => {
  it('is drawn in the transcript', () => {
    const deps = presentationFor(afterCompaction())

    expect(renderTranscript(deps.messageGroups.value)).toContain('props data type don’t match')
  })

  it('keeps the compaction card and the human turn in separate rows', () => {
    const deps = presentationFor(afterCompaction())

    // assistant reply, compaction divider, human turn — never one merged user block
    expect(deps.messageGroups.value.map((g) => g.messages.length)).toEqual([1, 1, 1])
  })

  it('still draws the card itself', () => {
    const deps = presentationFor(afterCompaction())
    const rows = deps.messageGroups.value.map((g) => g.messages[0])

    expect(rows.some((m) => m && isCompactionMessage(m))).toBe(true)
    expect(renderTranscript(deps.messageGroups.value)).toContain('Compacted 2 messages')
  })

  it('gives the human turn a rail pill, and the divider none', () => {
    const deps = presentationFor(afterCompaction())

    expect(deps.userPills.value.map((p) => p.preview)).toEqual([
      'props data type don’t match — check the clay enum',
    ])
  })

  it('does not split a compaction from a compaction before it', () => {
    const messages = [
      msg({ role: 'user', content: COMPACTION_ENVELOPE }),
      msg({ role: 'user', content: 'second sentence' }),
    ]
    const deps = presentationFor(messages)

    expect(deps.messageGroups.value).toHaveLength(2)
    expect(deps.userPills.value).toHaveLength(1)
  })

  it('leaves an ordinary burst of consecutive user messages in one block', () => {
    // The 2026-08-23 fix — a queued burst stays one bubble with every message drawn.
    const messages = [
      msg({ role: 'user', content: 'first' }),
      msg({ role: 'user', content: 'second' }),
    ]
    const deps = presentationFor(messages)

    expect(deps.messageGroups.value).toHaveLength(1)
    expect(renderTranscript(deps.messageGroups.value)).toContain('first')
    expect(renderTranscript(deps.messageGroups.value)).toContain('second')
  })
})

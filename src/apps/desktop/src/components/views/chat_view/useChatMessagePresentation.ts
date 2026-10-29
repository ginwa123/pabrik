import { computed, type Ref } from 'vue'
import { renderResponse, renderStreamingResponse, stripThinkingTags } from '@/helpers'
import { tryUnwrapToolOutput, type UnwrappedToolOutput } from '../../../helpers/unwrapToolOutput'
import {
  backgroundToShellData,
  isBackgroundCommandOutput,
  parseBackgroundCommandOutput,
} from '../../../helpers/isBackgroundCommandOutput'
import { indexSpawnSubAgentArgs, type SubAgentArgs } from '../../../helpers/parseSpawnSubAgentArgs'
import { type SubAgentProgressMap } from '../../../helpers/subagentProgress'
import { splitSkillEnvelope } from '../../../helpers/skillEnvelope'
import { isPillGroup } from '../../chat/activePill'
import { type UserPill } from '../../chat/UserPillRail.vue'
import {
  buildCompactChains,
  foldedNarrationMessageIds,
  foldedThoughtMessageIds,
  foldsIntoChain,
  type CompactChainItem,
} from '../../tool_outputs/compact/chain'
import { type ToolCardData } from '../../tool_outputs/ToolCard.vue'
import { type ChatViewMode } from '../../../stores/chatView'

export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp: Date
  tool_name?: string
  diffview_before?: string
  diffview_after?: string
  image_urls?: string[]
  video_urls?: string[]
  /** The attached files as a JSON array of `{name, mime, bytes}` — metadata only. */
  file_attachments?: string
  tool_calls_json?: string
  finish_reason?: string
  tool_call_id?: string
  /** JSON-stringified tool input arguments, filled by the same `tryUnwrapToolOutput` pipeline. */
  parameters?: string
  is_input?: boolean
  is_output?: boolean
  reasoning_content?: string
}

export interface MessageGroup {
  role: 'user' | 'assistant' | 'tool'
  messages: Message[]
  timestamp: Date
}

export interface ChatMessagePresentationDeps {
  messages: Ref<Message[]>
  expandedToolIds: Ref<Set<string>>
  subAgentProgressMap: Ref<SubAgentProgressMap>
  isPendingSession: Ref<boolean>
  sessionId: Ref<string>
  isRemoteLoadPending: Ref<boolean>
  mode: () => ChatViewMode
}

/** Both prefixes are recognised: older rows carry the XML envelope, not the JSON one. */
export const isCompactionMessage = (
  msg: { role: string; content: string } | undefined,
): boolean => {
  if (!msg) return false
  if (msg.role !== 'user') return false
  const trimmed = msg.content.trimStart()
  if (trimmed.startsWith('{"compact_messages"')) return true
  return trimmed.startsWith('<compact_messages>')
}

export const toolExpandKey = (msg: Message, groupIndex: number, idx: number): string => {
  return msg.id || msg.tool_call_id || `pos-${groupIndex}-${idx}`
}

export function useChatMessagePresentation(deps: ChatMessagePresentationDeps) {
  const {
    messages,
    expandedToolIds,
    subAgentProgressMap,
    isPendingSession,
    sessionId,
    isRemoteLoadPending,
    mode,
  } = deps

  const filteredMessages = computed(() =>
    messages.value.filter((m) => {
      // Always keep tool_calls messages even if content is only thinking tags
      if (m.finish_reason === 'tool_calls') return true
      if ((m.image_urls?.length ?? 0) > 0) return true
      if ((m.file_attachments?.length ?? 0) > 0) return true
      if (m.role === 'tool') return true
      if (m.role === 'assistant' && m.reasoning_content && m.reasoning_content.trim() !== '') {
        return true
      }
      const stripped = stripThinkingTags(m.content)
      return stripped && stripped.trim() !== ''
    }),
  )

  const groupKey = (group: MessageGroup): string =>
    group.messages[0]?.id ?? `empty-${group.timestamp.getTime()}`

  const messageGroups = computed((): MessageGroup[] => {
    const groups: MessageGroup[] = []

    for (const msg of filteredMessages.value) {
      const lastGroup = groups[groups.length - 1]

      if (lastGroup && lastGroup.role === msg.role) {
        lastGroup.messages.push(msg)
        if (msg.timestamp > lastGroup.timestamp) {
          lastGroup.timestamp = msg.timestamp
        }
      } else {
        groups.push({
          role: msg.role as 'user' | 'assistant' | 'tool',
          messages: [msg],
          timestamp: msg.timestamp,
        })
      }
    }

    // Drop groups with nothing renderable BEFORE the VirtualScroller ever sees them.
    return groups.filter((g, i) => hasBubbleContent(g, i))
  })

  const isInitializing = computed(
    () =>
      !isPendingSession.value &&
      (!sessionId.value || (isRemoteLoadPending.value && messageGroups.value.length === 0)),
  )

  const groupKeyForMessageId = (messageId: string): string | null => {
    if (!messageId) return null
    const g = messageGroups.value.find((grp) => grp.messages.some((m) => m.id === messageId))
    return g ? groupKey(g) : null
  }

  // One pill per user group; click jumps the scroller to that group. Per-group (not per-message)
  // because VirtualScroller items ARE groups — scrollToItem(groupIndex) is exact.
  const userPills = computed((): UserPill[] => {
    const pills: UserPill[] = []
    messageGroups.value.forEach((g, i) => {
      // Real user turns only: bg-output groups are role=user on the wire
      // but render as tool cards, compaction envelopes are system
      // artifacts — neither gets a pill (see isPillGroup).
      const first = g.messages[0]
      if (!isPillGroup(g.role, isBgOnlyGroup(g), !!first && isCompactionMessage(first))) return
      // Per message, not on the join: a `/skill-` turn carries the loaded bodies
      // as a trailing envelope, and the preview is for the human's sentence.
      let text = ''
      let skills = 0
      for (const m of g.messages) {
        const parts = splitSkillEnvelope(m.content || '')
        text += (text === '' ? '' : '\n') + parts.text
        skills += parts.skills.length
      }
      const label = text.trim().slice(0, 60) || 'Image'
      const preview = skills > 0 ? `${label} +${skills} skill${skills === 1 ? '' : 's'}` : label
      pills.push({ groupIndex: i, key: groupKey(g), preview })
    })
    return pills
  })

  const unwrappedByMessageId = computed((): Map<string, UnwrappedToolOutput | null> => {
    const map = new Map<string, UnwrappedToolOutput | null>()
    for (const m of messages.value) {
      if (m.role !== 'tool') {
        map.set(m.id, null)
        continue
      }
      map.set(m.id, tryUnwrapToolOutput(m.content))
    }
    return map
  })

  const innerToolData = (m: Message): unknown => {
    const unwrapped = unwrappedByMessageId.value.get(m.id)
    if (unwrapped === null || unwrapped === undefined) return m.content // legacy
    return unwrapped.data ?? m.content // error case: fall back to full content
  }

  const getParametersForMessage = (m: Message): string => {
    return unwrappedByMessageId.value.get(m.id)?.parameters ?? '{}'
  }

  const compactChains = computed(
    (): Map<number, CompactChainItem[]> =>
      mode() === 'compact' ? buildCompactChains(messageGroups.value, toolCardsFor) : new Map(),
  )

  const foldedThoughtIds = computed((): Set<string> => foldedThoughtMessageIds(compactChains.value))

  const foldedNarrationIds = computed(
    (): Set<string> => foldedNarrationMessageIds(compactChains.value),
  )

  const visibleReasoning = (group: MessageGroup): Message[] =>
    group.messages.filter(
      (m) =>
        typeof m.reasoning_content === 'string' &&
        m.reasoning_content.trim() !== '' &&
        !foldedThoughtIds.value.has(m.id),
    )

  const answeredMessages = (group: MessageGroup): Message[] =>
    mode() === 'compact'
      ? group.messages.filter((m) => !foldedNarrationIds.value.has(m.id))
      : group.messages

  const subAgentArgsByToolCallId = computed((): Map<string, SubAgentArgs[]> => {
    const index = new Map<string, SubAgentArgs[]>()
    for (const group of messageGroups.value) {
      if (group.role !== 'assistant') continue
      for (const msg of group.messages) {
        if (typeof msg.tool_calls_json !== 'string') continue
        for (const [toolCallId, args] of indexSpawnSubAgentArgs(msg.tool_calls_json)) {
          index.set(toolCallId, args)
        }
      }
    }
    return index
  })

  /** The cards of one tool group, in order. Both views draw the same cards. */
  const toolCardsFor = (group: MessageGroup, groupIndex: number): ToolCardData[] =>
    group.messages.map((msg, idx) => ({
      message: msg,
      content: innerToolData(msg),
      parameters: getParametersForMessage(msg),
      expanded: expandedToolIds.value.has(toolExpandKey(msg, groupIndex, idx)),
      expandKey: toolExpandKey(msg, groupIndex, idx),
      subAgentProgress: msg.tool_call_id
        ? (subAgentProgressMap.value[msg.tool_call_id] ?? null)
        : null,
      subAgentArgs: msg.tool_call_id
        ? (subAgentArgsByToolCallId.value.get(msg.tool_call_id) ?? null)
        : null,
    }))

  const standaloneCardsFor = (group: MessageGroup, groupIndex: number): ToolCardData[] =>
    toolCardsFor(group, groupIndex).filter((card) => !foldsIntoChain(card))

  const renderMessageHtml = (msg: Message): string =>
    msg.id.startsWith('streaming-')
      ? renderStreamingResponse(msg.content, msg.role, msg.tool_name)
      : renderResponse(
          msg.content,
          msg.role,
          msg.tool_name,
          msg.diffview_before,
          msg.diffview_after,
          msg.finish_reason,
          msg.tool_calls_json,
        )

  const isBgUserMsg = (m: { content?: string }): boolean =>
    !!m.content && isBackgroundCommandOutput(m.content)

  const bgShellData = (m: { content?: string }): unknown => {
    const pr = m.content ? parseBackgroundCommandOutput(m.content) : null
    return pr ? backgroundToShellData(pr) : (m.content ?? '')
  }
  // A user group made ONLY of background completions renders as a transparent left-aligned tool card,
  // not the blue right bubble (background completions are role=user on the wire, tool-styled in
  // pixels — see helpers/isBackgroundCommandOutput).
  const isBgOnlyGroup = (group: { role: string; messages: { content?: string }[] }): boolean =>
    group.role === 'user' && group.messages.length > 0 && group.messages.every(isBgUserMsg)

  const groupToolNames = computed((): (string | null)[] => {
    const renderedToolCallIds = new Set<string>()
    for (const g of messageGroups.value) {
      if (g.role !== 'tool') continue
      for (const m of g.messages) {
        if (m.tool_call_id) renderedToolCallIds.add(m.tool_call_id)
      }
    }

    return messageGroups.value.map((group, i) => {
      if (group.role !== 'assistant') return null

      // Same-group tool rows (rare but possible when an assistant message
      // carries tool_calls_json AND a tool result) → no pill needed.
      const nextGroup = messageGroups.value[i + 1]
      if (nextGroup?.role === 'tool') {
        return null
      }

      for (const msg of group.messages) {
        // The backend always serializes tool_calls_json as a JSON STRING, but older events (or any
        // future array-shaped regression) must not crash the render.
        if (typeof msg.tool_calls_json === 'string' && msg.tool_calls_json.trim()) {
          try {
            const parsed = JSON.parse(msg.tool_calls_json)
            // tool_calls_json IS the array directly: [{id, type, function: {name}}]
            if (Array.isArray(parsed) && parsed.length > 0) {
              // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
              const names = parsed.map((tc: any) => tc.function?.name || tc.name || 'unknown')

              // If EVERY tool call in this group already has a rendered tool row somewhere in the
              // transcript, the structured cards are the source of truth — suppress the pill entirely.
              // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; tool_calls_json shape is intentionally opaque.
              const allRendered = parsed.every((tc: any) => {
                const id = tc?.id
                return typeof id === 'string' && renderedToolCallIds.has(id)
              })
              if (allRendered) return null

              return names.join(', ')
            }
          } catch {}
        }

        if (msg.finish_reason === 'tool_calls') {
          // We can't match by id here (tool_calls_json is missing), so fall back to the adjacency
          // heuristic: if a tool group appears ANYWHERE in the transcript after this group, the tool
          // call was rendered → no pill.
          let hasLaterTool = false
          for (let j = i + 1; j < messageGroups.value.length; j++) {
            if (messageGroups.value[j]?.role === 'tool') {
              hasLaterTool = true
              break
            }
          }
          if (hasLaterTool) return null
          return '...'
        }
      }

      return null
    })
  })

  const hasVisibleContent = (m: Message): boolean => {
    const stripped = stripThinkingTags(m.content || '')
    return stripped.trim().length > 0
  }

  const hasBubbleContent = (group: MessageGroup, groupIndex: number): boolean => {
    if (group.role === 'user') {
      return group.messages.some(
        (m) =>
          (m.image_urls?.length ?? 0) > 0 ||
          (m.file_attachments?.length ?? 0) > 0 ||
          hasVisibleContent(m) ||
          !!(m.reasoning_content && m.reasoning_content.trim() !== ''),
      )
    }
    if (group.role === 'tool') {
      return group.messages.length > 0
    }
    if (group.role === 'assistant') {
      const hasToolHeader = groupToolNames.value[groupIndex] !== null
      const hasReasoning = group.messages.some(
        (m) => m.reasoning_content && m.reasoning_content.trim() !== '',
      )
      return hasToolHeader || hasReasoning || group.messages.some(hasVisibleContent)
    }
    return false
  }

  return {
    filteredMessages,
    groupKey,
    messageGroups,
    isInitializing,
    groupKeyForMessageId,
    userPills,
    unwrappedByMessageId,
    innerToolData,
    getParametersForMessage,
    compactChains,
    foldedThoughtIds,
    foldedNarrationIds,
    visibleReasoning,
    answeredMessages,
    subAgentArgsByToolCallId,
    toolCardsFor,
    standaloneCardsFor,
    renderMessageHtml,
    isBgUserMsg,
    bgShellData,
    isBgOnlyGroup,
    groupToolNames,
    hasVisibleContent,
    hasBubbleContent,
  }
}

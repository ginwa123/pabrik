/** The items a compact chain draws, in transcript order: the calls of one agent turn, the thoughts
 * the agent had between them, and the narration it wrote on the way to a call. */
import { stripThinkingTags } from '@/helpers/stripTags'
import type { ToolCardData } from '../ToolCard.vue'

export interface ChainGroup {
  role: string
  messages: {
    id: string
    content?: string
    reasoning_content?: string
    finish_reason?: string
  }[]
}

export interface CompactToolItem {
  kind: 'tool'
  key: string
  card: ToolCardData
}

export interface CompactThoughtItem {
  kind: 'thought'
  key: string
  messageId: string
  text: string
}

export interface CompactNarrationItem {
  kind: 'narration'
  key: string
  messageId: string
  text: string
}

export type CompactChainItem = CompactToolItem | CompactThoughtItem | CompactNarrationItem

/** The stable key of the thought a message carries. */
export const thoughtKey = (messageId: string): string => `thought-${messageId}`

/** The key of a message's narration row: the prefix keeps it from colliding with the same
 * message's thought row. */
export const narrationKey = (messageId: string): string => `narration-${messageId}`

/** The reasons that close a turn: the message carrying one is the agent's ANSWER, so it keeps its
 * own place in the transcript. `awaiting_user` is written by the loop when the message ends with
 * an `ask_user` block, not by the provider. */
const TURN_ENDS: ReadonlySet<string> = new Set([
  'stop',
  'length',
  'content_filter',
  'awaiting_user',
])

const endsTurn = (finishReason: string | undefined): boolean =>
  TURN_ENDS.has((finishReason ?? '').trim())

/** A call that IS the answer, so the chain must not swallow it: a presented file is drawn by its
 * own card or not at all. */
const STANDALONE_TOOLS: ReadonlySet<string> = new Set(['present_files'])

export const foldsIntoChain = (card: ToolCardData): boolean =>
  !STANDALONE_TOOLS.has(card.message.tool_name ?? '')

const isStreaming = (messageId: string): boolean => messageId.startsWith('streaming-')

/** One item per call, per non-empty thought and per narrative line, keyed by the group that draws
 * the chain (its first tool group). A turn ends at the assistant message that stops or asks, so
 * what the agent said on the way there folds into the card instead of stacking above it. */
export function buildCompactChains<G extends ChainGroup>(
  groups: G[],
  cardsOf: (group: G, groupIndex: number) => ToolCardData[],
): Map<number, CompactChainItem[]> {
  const chains = new Map<number, CompactChainItem[]>()
  let items: CompactChainItem[] = []
  let narration: CompactNarrationItem[] = []
  let at: number | null = null
  const commitNarration = () => {
    items.push(...narration)
    narration = []
  }
  const flush = () => {
    if (at !== null && items.length > 0) chains.set(at, items)
    items = []
    narration = []
    at = null
  }
  groups.forEach((group, groupIndex) => {
    if (group.role === 'tool') {
      const cards = cardsOf(group, groupIndex)
      if (at === null) at = groupIndex
      commitNarration()
      for (const card of cards) {
        if (foldsIntoChain(card)) items.push({ kind: 'tool', key: card.expandKey, card })
      }
      return
    }
    if (group.role === 'assistant') {
      for (const message of group.messages) {
        const thought = (message.reasoning_content ?? '').trim()
        if (thought !== '') {
          items.push({
            kind: 'thought',
            key: thoughtKey(message.id),
            messageId: message.id,
            text: thought,
          })
        }
        if (isStreaming(message.id) || endsTurn(message.finish_reason)) continue
        const text = stripThinkingTags(message.content).trim()
        if (text !== '') {
          narration.push({
            kind: 'narration',
            key: narrationKey(message.id),
            messageId: message.id,
            text,
          })
        }
      }
      if (group.messages.some((message) => endsTurn(message.finish_reason))) flush()
      return
    }
    flush()
  })
  flush()
  return chains
}

const isTextItem = (item: CompactChainItem): item is CompactThoughtItem | CompactNarrationItem =>
  item.kind === 'thought' || item.kind === 'narration'

const foldedMessageIds = (
  chains: Map<number, CompactChainItem[]>,
  kind: 'thought' | 'narration',
): Set<string> => {
  const ids = new Set<string>()
  for (const items of chains.values()) {
    for (const item of items) {
      if (isTextItem(item) && item.kind === kind) ids.add(item.messageId)
    }
  }
  return ids
}

/** The message ids whose thought a chain already draws, so their own group draws nothing. */
export const foldedThoughtMessageIds = (chains: Map<number, CompactChainItem[]>): Set<string> =>
  foldedMessageIds(chains, 'thought')

/** The message ids whose narration a chain already draws, so it does not stack above the card. */
export const foldedNarrationMessageIds = (chains: Map<number, CompactChainItem[]>): Set<string> =>
  foldedMessageIds(chains, 'narration')

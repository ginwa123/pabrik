/** The items a compact chain draws, in transcript order: the tool calls of one
 * agent turn and the thoughts the agent had between them. */
import type { ToolCardData } from '../ToolCard.vue'

export interface ChainGroup {
  role: string
  messages: {
    id: string
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

export type CompactChainItem = CompactToolItem | CompactThoughtItem

/** The stable key of the thought a message carries. */
export const thoughtKey = (messageId: string): string => `thought-${messageId}`

/** One item per tool call and per non-empty thought, in transcript order, keyed by the group that
 * draws the chain (its first tool group). A turn ends at the assistant message that stops, so a
 * turn's thoughts fold into the same chain as its calls instead of leaking out below the card. */
export function buildCompactChains<G extends ChainGroup>(
  groups: G[],
  cardsOf: (group: G, groupIndex: number) => ToolCardData[],
): Map<number, CompactChainItem[]> {
  const chains = new Map<number, CompactChainItem[]>()
  let items: CompactChainItem[] = []
  let at: number | null = null
  const flush = () => {
    if (at !== null && items.length > 0) chains.set(at, items)
    items = []
    at = null
  }
  groups.forEach((group, groupIndex) => {
    if (group.role === 'tool') {
      if (at === null) at = groupIndex
      for (const card of cardsOf(group, groupIndex)) {
        items.push({ kind: 'tool', key: card.expandKey, card })
      }
      return
    }
    if (group.role === 'assistant') {
      for (const message of group.messages) {
        const text = (message.reasoning_content ?? '').trim()
        if (text === '') continue
        items.push({ kind: 'thought', key: thoughtKey(message.id), messageId: message.id, text })
      }
      if (group.messages.some((m) => m.finish_reason === 'stop')) flush()
      return
    }
    flush()
  })
  flush()
  return chains
}

/** The message ids whose thought a chain already draws, so their own group draws nothing. */
export function foldedThoughtMessageIds(chains: Map<number, CompactChainItem[]>): Set<string> {
  const ids = new Set<string>()
  for (const items of chains.values()) {
    for (const item of items) {
      if (item.kind === 'thought') ids.add(item.messageId)
    }
  }
  return ids
}

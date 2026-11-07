/** A tab's name: the live session feed, and following a session-id change in place. */
import type { Ref } from 'vue'
import { ownerOf, type Tab } from '../helpers/tabTarget'
import { withTitle } from './tabsRows'

/** The slice of the SSE bus the title feed needs, so the store never reaches for a global. */
export type TitleFeed = {
  on: (
    channel: 'session',
    handler: (event: { action: string; id: string; name: string }) => void,
  ) => () => void
}

type TitleDeps = {
  tabs: Ref<Tab[]>
  activeTabId: Ref<string>
  persist: () => void
  byKey: (key: string) => Tab | null
}

export function createTitles(deps: TitleDeps) {
  const { tabs, activeTabId } = deps
  let offFeed: (() => void) | null = null

  function setTabTitle(id: string, title: string): void {
    const next = withTitle(tabs.value, id, title)
    if (!next) return
    tabs.value = next
    deps.persist()
  }

  function setChatTitle(sessionId: string, name: string): void {
    const tab = tabs.value.find(
      (candidate) => candidate.kind === 'chat' && candidate.key === `chat:${sessionId}`,
    )
    if (tab) setTabTitle(tab.id, name)
  }

  /** Follow session renames; without a feed the titles keep what the chats list published. */
  function initTitleFeed(feed: TitleFeed | null): void {
    if (offFeed || !feed) return
    offFeed = feed.on('session', (event) => {
      if (event.action !== 'created' && event.action !== 'updated') return
      setChatTitle(event.id, event.name)
    })
  }

  function disposeTitleFeed(): void {
    offFeed?.()
    offFeed = null
  }

  /** Follow a session-id change *in place*: the tab, and every artifact it opened, move with it. */
  function renameChatTab(oldSessionId: string, newSessionId: string): boolean {
    if (!oldSessionId || !newSessionId || oldSessionId === newSessionId) return false
    const newKey = `chat:${newSessionId}`
    const renamed = deps.byKey(`chat:${oldSessionId}`)
    if (!renamed) return false

    const alreadyOpen = deps.byKey(newKey)
    if (alreadyOpen && alreadyOpen.id !== renamed.id) {
      // Two anchors for one session is the one thing a row must never hold: drop the dead pointer.
      tabs.value = tabs.value.filter((tab) => tab.id !== renamed.id)
      activeTabId.value = alreadyOpen.id
      deps.persist()
      return true
    }

    tabs.value = tabs.value.map((tab) => {
      if (tab.id === renamed.id) {
        return {
          ...tab,
          key: newKey,
          query: { ...tab.query, session: newSessionId },
          owner: newSessionId,
        }
      }
      // Artifacts the session opened move with it: the row is keyed by the session id.
      if (ownerOf(tab) === oldSessionId) return { ...tab, owner: newSessionId }
      return tab
    })
    deps.persist()
    return true
  }

  return { initTitleFeed, disposeTitleFeed, renameChatTab, setChatTitle, setTabTitle }
}

import { inject, type InjectionKey } from 'vue'

/**    * What the strip needs from the layout that owns the router and the tab funnel. The strip renders and
 * asks; it never navigates by itself, so every tab gesture takes the same path a sidebar click takes. */
export type TabStripActions = {
  /** Make this tab the active one and move the URL to its target. */
  activate: (tabId: string) => void
  /** Close it. The session's own (pinned) tab refuses. */
  close: (tabId: string) => void
  /** Open — or focus — the changes of the file this tab shows. */
  openDiff: (tabId: string) => void
}

export const TAB_STRIP_ACTIONS_KEY: InjectionKey<TabStripActions> = Symbol(
  'tabStripActions',
) as InjectionKey<TabStripActions>

/** `null` outside an AppLayout subtree (unit tests render the strip with explicit handlers). */
export function useInjectTabStripActions(): TabStripActions | null {
  return inject(TAB_STRIP_ACTIONS_KEY, null)
}

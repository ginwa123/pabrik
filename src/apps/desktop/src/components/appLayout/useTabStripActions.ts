import { provide } from 'vue'
import type { OpenInCodeEditorFn } from '../../composables/useCodeEditor'
import { TAB_STRIP_ACTIONS_KEY, type TabStripActions } from '../../composables/useTabStrip'
import { isDiffQuery } from '../../helpers/tabTarget'
import type { useTabsStore } from '../../stores/tabs'

type Deps = {
  tabsStore: ReturnType<typeof useTabsStore>
  applyActiveTabToUrl: () => void
  openInCodeEditor: OpenInCodeEditorFn
  /** The session's working directory, for a tab whose URL carries none. */
  cwd: () => string
}

/**    * The layout owns the router and the tab funnel, so it is the only place a tab gesture becomes
 * navigation: a click on a tab takes exactly the path a sidebar click takes. Provided once, read by
 * the session strip. */
export function useProvideTabStripActions(deps: Deps): TabStripActions {
  const actions: TabStripActions = {
    activate: (tabId) => {
      deps.tabsStore.activate(tabId)
      deps.applyActiveTabToUrl()
    },
    close: (tabId) => {
      deps.tabsStore.close(tabId)
      deps.applyActiveTabToUrl()
    },
    openDiff: (tabId) => {
      const tab = deps.tabsStore.tabs.find((candidate) => candidate.id === tabId)
      if (!tab || isDiffQuery(tab.query)) return
      const file = tab.query.file ?? ''
      const cwd = tab.query.cwd || deps.cwd()
      if (!file || !cwd) return
      void deps.openInCodeEditor({ filePath: file, cwd, diff: true })
    },
  }
  provide<TabStripActions>(TAB_STRIP_ACTIONS_KEY, actions)
  return actions
}

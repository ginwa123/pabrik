/**    * The URL funnel: the one place a navigation becomes (or re-uses) a tab. Every route lands here, so no
 * call site has to know the strip exists — and the tab that a URL names is resolved **inside that
 * session's row**, which is what makes two sessions two strips. */
import {
  hasTabIdentity,
  migrateLegacySettingsTab,
  ownerOf,
  ownerOfTarget,
  sameRouteQuery,
  shouldTabify,
  tabKeyVariants,
  withTabParam,
  type Tab,
  type TabQuery,
} from '../helpers/tabTarget'
import { tabQueryOf } from './tabsStorage'

export interface SyncResult {
  /** The navigation the layout should apply. */
  path: string
  query: TabQuery
  /** True when the current URL differs from `path`/`query` (apply with replace). */
  changed: boolean
}

export type FunnelDeps = {
  /** False leaves the URL exactly as it came in (the Settings escape hatch). */
  enabled: () => boolean
  byId: (id: string) => Tab | null
  findExisting: (variants: string[], owner: string) => Tab | null
  refreshFromInput: (tab: Tab, input: { path: string; query: TabQuery }) => void
  rekeyTab: (id: string, key: string, query: TabQuery) => void
  activate: (id: string) => void
  open: (input: {
    path: string
    query: Record<string, unknown>
    itemType?: string | null
    owner: string
  }) => Tab
}

export function createFunnel(deps: FunnelDeps) {
  const untouched = (
    path: string,
    plain: TabQuery,
    query: Record<string, unknown>,
  ): SyncResult => ({
    path,
    query: plain,
    changed: !sameRouteQuery(plain, query),
  })

  return function syncFromTarget(
    path: string,
    rawQuery: Record<string, unknown>,
    itemType?: string | null,
  ): SyncResult {
    // Migrate pre-tab-mode kanban-settings deep links (`?tab=<section>`) to `?section=` before the
    // tab ID logic runs — otherwise a legacy value like `?tab=memories` is mistaken for an unknown
    // browser tab ID and rewritten to a fresh `tab_xxx`, dropping the section.
    const query = migrateLegacySettingsTab(path, rawQuery)
    const plain = tabQueryOf(query)
    const urlTabId = typeof query.tab === 'string' ? query.tab : ''

    if (!deps.enabled() || !shouldTabify(path, query)) return untouched(path, plain, query)
    // A target the engine cannot name (a document page, most of all) keeps the URL it already had:
    // the funnel never invents a `home` tab for a page that is not the chats list.
    if (!hasTabIdentity(path, plain)) return untouched(path, plain, query)

    const variants = tabKeyVariants(path, query, itemType)
    const canonical = variants[0] ?? ''
    const owner = ownerOfTarget(path, plain)
    const named = urlTabId ? deps.byId(urlTabId) : null
    // A tab id from another session's row is not this URL's tab: the funnel corrects the address
    // instead of moving a tab across rows.
    const candidates = [
      named && variants.includes(named.key) && ownerOf(named) === owner ? named : null,
      deps.findExisting(variants, owner),
    ]
    const existing = candidates.find((candidate): candidate is Tab => candidate !== null)

    const tab = existing ?? deps.open({ path, query: plain, itemType, owner })
    if (existing) {
      deps.refreshFromInput(existing, { path, query: plain })
      deps.rekeyTab(existing.id, canonical, plain)
    }
    deps.activate(tab.id)
    const desired = withTabParam(plain, tab.id)
    return { path, query: desired, changed: !sameRouteQuery(desired, query) }
  }
}

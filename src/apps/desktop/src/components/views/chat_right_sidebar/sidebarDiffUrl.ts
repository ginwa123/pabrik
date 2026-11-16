import type { RouteLocationNormalizedLoaded, Router } from 'vue-router'

export type PanelTab = 'files' | 'pr' | 'conversation' | 'commits' | 'checks' | 'evals'

export const readTabParam = (route: RouteLocationNormalizedLoaded): PanelTab | null => {
  const v = route.query.panel
  return v === 'files' ||
    v === 'pr' ||
    v === 'conversation' ||
    v === 'commits' ||
    v === 'checks' ||
    v === 'evals'
    ? v
    : null
}

export const syncTabParam = (
  router: Router,
  route: RouteLocationNormalizedLoaded,
  tab: PanelTab | null,
) => {
  // No router means no URL to keep in sync — the same reason the read above is guarded.
  if (!router || !route) return
  const query = { ...route.query }
  if (tab) query.panel = tab
  else delete query.panel
  router.replace({ path: route.path, query }).catch(() => {})
}

// "⚠ Conflicts only" filter.
export const readConflictsParam = (route: RouteLocationNormalizedLoaded): boolean =>
  route.query.conflicts === '1'

export const syncConflictsParam = (
  router: Router,
  route: RouteLocationNormalizedLoaded,
  on: boolean,
) => {
  if (!router || !route) return
  const query = { ...route.query }
  if (on) query.conflicts = '1'
  else delete query.conflicts
  router.replace({ path: route.path, query }).catch(() => {})
}

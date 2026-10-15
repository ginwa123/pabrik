import type { Router } from 'vue-router'

/**  * Open a router location in a real browser tab and stay put. Single funnel for every "Open in new
 * tab" affordance (chat rows, workspace rows, task rows/cards, context menus, Ctrl/Cmd+click,
 * middle-click) so the target shape and window features stay consistent everywhere. */
export function openInNewTab(
  router: Router,
  location: { path: string; query: Record<string, string> },
): void {
  const href = router.resolve({ path: location.path, query: location.query }).href
  window.open(href, '_blank', 'noopener')
}

import type { Router } from 'vue-router'

/** Open a router location in a real browser tab and stay put. */
export function openInNewTab(
  router: Router,
  location: { path: string; query: Record<string, string> },
): void {
  const href = router.resolve({ path: location.path, query: location.query }).href
  window.open(href, '_blank', 'noopener')
}

import { onScopeDispose, ref, type Ref } from 'vue'

export const MOBILE_QUERY = '(max-width: 767px)'

export type MediaQuerySource = {
  matchesQuery: (query: string) => boolean
  subscribe: (query: string, listener: (matches: boolean) => void) => () => void
}

export type ResponsiveLayoutOptions = {
  onChange?: (isMobile: boolean) => void
}

/** jsdom has no layout engine and a headless run has no viewport, so a source that cannot answer
 * reports the wide layout: every existing desktop surface keeps rendering exactly as before. */
const canQueryViewport = () =>
  typeof window !== 'undefined' && typeof window.matchMedia === 'function'

const browserMediaQueries: MediaQuerySource = {
  matchesQuery: (query) => (canQueryViewport() ? window.matchMedia(query).matches : false),
  subscribe: (query, listener) => {
    if (!canQueryViewport()) return () => {}
    const list = window.matchMedia(query)
    const handler = (event: MediaQueryListEvent) => listener(event.matches)
    list.addEventListener('change', handler)
    return () => list.removeEventListener('change', handler)
  },
}

export function useResponsiveLayout(
  source: MediaQuerySource = browserMediaQueries,
  options: ResponsiveLayoutOptions = {},
): { isMobile: Ref<boolean> } {
  const isMobile = ref(source.matchesQuery(MOBILE_QUERY))
  const unsubscribe = source.subscribe(MOBILE_QUERY, (matches) => {
    isMobile.value = matches
    options.onChange?.(matches)
  })
  onScopeDispose(unsubscribe)
  return { isMobile }
}

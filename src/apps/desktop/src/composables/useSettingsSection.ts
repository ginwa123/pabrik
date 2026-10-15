import { computed, onMounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'

export interface SettingsSectionDef {
  id: string
  label: string
}

interface UseSettingsSectionOptions {
  /** Valid section ids, in sidebar order. */
  sections: readonly string[]
  /** Section shown when the URL + storage have nothing usable. */
  defaultSection: string
  /** localStorage key for the last-open section (fallback below the URL). */
  storageKey: string
}

/**
 * URL-synced settings-section state, shared by the user + workspace
 * settings pages. Read order is URL (`?section=`) → localStorage →
 * default; writes go through `router.replace` so refresh, Back/Forward
 * and shared links restore the open section. The default section is
 * stripped from the query to keep URLs clean.
 *
 * No watchers: the section is a writable computed over the route, and a
 * local ref backs it when the component mounts without a router (unit
 * tests). Same shape as the per-page implementations this replaces.
 */
export function useSettingsSection(options: UseSettingsSectionOptions) {
  const { sections, defaultSection, storageKey } = options

  const isKnown = (value: unknown): value is string =>
    typeof value === 'string' && (sections as readonly string[]).includes(value)

  function readStored(): string | null {
    try {
      const saved = localStorage.getItem(storageKey)
      return isKnown(saved) ? saved : null
    } catch (e) {
      // Best-effort UI chrome, but the failure stays visible: without this
      // log a broken storage backend is indistinguishable from 'no saved
      // section' (local/no-silent-fallback-catch).
      console.warn('[settings-section] stored section unreadable, using default', e)
      return null
    }
  }

  // `useRoute`/`useRouter` throw outside a router context (unit tests) —
  // fall back to router-less mode where the local ref is the source.
  let route: ReturnType<typeof useRoute> | null = null
  let router: ReturnType<typeof useRouter> | null = null
  try {
    route = useRoute()
    router = useRouter()
  } catch (e) {
    // Router-less mount (unit tests): the local ref below is the source.
    // Logged so a missing router in production is visible, not silent.
    console.warn('[settings-section] no router, using local section state', e)
    route = null
    router = null
  }

  const local = ref<string>(readStored() ?? defaultSection)

  const section = computed<string>({
    get() {
      if (route) {
        const raw = route.query.section
        const value = Array.isArray(raw) ? raw[0] : raw
        if (isKnown(value)) return value
        return readStored() ?? defaultSection
      }
      return local.value
    },
    set(next) {
      if (!isKnown(next)) return
      local.value = next
      try {
        localStorage.setItem(storageKey, next)
      } catch {
        // Best-effort persistence only: the URL (source of truth) is written below, and `local`
        // already holds the new section, so a failed write only affects the next cold load's
        // fallback — the failure cannot reach the user as a wrong section.
      }
      if (!router || !route) return
      const rest = { ...route.query }
      if (next === defaultSection) delete rest.section
      else rest.section = next
      void router.replace({ query: rest })
    },
  })

  function select(next: string): void {
    section.value = next
  }

  // Mount normalization: the getter falls back to localStorage when the
  // URL has no `?section=`, which would render the stored section with a
  // clean URL. Rewrite the URL to reflect the section actually shown,
  // and persist a deep link to storage so the next clean load restores
  // it. Replace, not push — mount is not a navigation.
  onMounted(() => {
    if (!router || !route) return
    try {
      const actual = section.value
      local.value = actual
      try {
        localStorage.setItem(storageKey, actual)
      } catch {
        /* private mode — URL below is the source of truth */
      }
      const raw = route.query.section
      const value = Array.isArray(raw) ? raw[0] : raw
      const urlValid = isKnown(value) ? (value as string) : undefined
      if (actual === defaultSection) {
        if (urlValid !== undefined || raw !== undefined) {
          const rest = { ...route.query }
          delete rest.section
          void router.replace({ query: rest }).catch(() => {})
        }
      } else if (urlValid !== actual) {
        void router.replace({ query: { ...route.query, section: actual } }).catch(() => {})
      }
    } catch {
      /* router absent in tests */
    }
  })

  return { section, select }
}

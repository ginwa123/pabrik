import * as api from '../../../api'
import { formatRelativeTime } from '../../../helpers/relativeTime'
import type { ChatsNavItem } from './chatsListRows'

export function useChatsTouched(deps: { navItems: { readonly value: ChatsNavItem[] } }) {
  const { navItems } = deps

  // Public methods for parent to call Amber stale-dot clear (yellow-dot-fix): optimistic patch +
  // best-effort backend touch. isStale() predicate is unchanged — clearing the dot is done by
  // aligning last_human_touched_at to updated_at.
  const optimisticClearStaleDot = (id: string) => {
    const item = navItems.value.find((i) => i.id === id)
    if (item && item.updated_at) {
      item.last_human_touched_at = item.updated_at
      item.relativeTime = formatRelativeTime(item.last_human_touched_at)
    }
  }

  // Loop-guard (touched-echo fix): fireSessionTouched fires at most ONCE per sessionId per component
  // lifetime.
  const touchedFiredFor = new Set<string>()
  const touchedAtMs = new Map<string, number>()
  // Echo window: a session.updated arriving within this long after our
  // own touched POST is assumed to be the backend echo of that POST,
  // not an independent rename — skip the refetch for it.
  const TOUCH_ECHO_SUPPRESS_MS = 5000

  const fireSessionTouched = (id: string) => {
    if (!id || touchedFiredFor.has(id)) return
    touchedFiredFor.add(id)
    touchedAtMs.set(id, Date.now())
    api.markSessionTouched(id).catch((e) => {
      // Allow retry on failure: a failed stamp never reached the DB,
      // so no SSE echo is coming — drop the guards.
      touchedFiredFor.delete(id)
      touchedAtMs.delete(id)
      console.error('Failed to mark session touched:', e)
    })
  }

  return { optimisticClearStaleDot, fireSessionTouched, touchedAtMs, TOUCH_ECHO_SUPPRESS_MS }
}

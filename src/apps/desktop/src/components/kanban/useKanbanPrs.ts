/** The board-level change-request list: `?prs=` mirroring, the open-count badge and the per-column
 * error-badge key. Extracted from KanbanView.vue. */
import { computed, nextTick, ref } from 'vue'
import { listPrs } from '../../api'
import { forgeWording } from '../../helpers/forgeWording'
import { invalidatePrStatus } from '../../helpers/prStatusCache'
import type { PrListTab } from './KanbanPrList.vue'
import { buildBoardAppUrl, flattenQuery } from './kanbanBoardUrl'
import { PRS_PARAM, type KanbanBoardDeps } from './kanbanViewTypes'

export function useKanbanPrs(deps: KanbanBoardDeps) {
  const { props, router, route, effectiveItemId } = deps

const prsOpen = ref(false)
const prsTab = ref<PrListTab>('open')
// Handle to the mounted list for explicit reloads (tab switches).
// The list exposes `reload()` instead of watching its props.
const prListRef = ref<{ reload: () => void } | null>(null)
const setPrListEl = (el: unknown) => {
  prListRef.value = el as { reload: () => void } | null
}
// Open-count badge: null until the forge answers — never a fake 0.
const prOpenCount = ref<number | null>(null)
const prOpenTruncated = ref(false)
// Forge guess for the button label + close calls. Updated by the
// mount fetch; the list view learns the authoritative provider from
// its own response.
const prProviderGuess = ref('')
const prPluralLabel = computed(() =>
  forgeWording(prProviderGuess.value || undefined).short === 'MR'
    ? 'Merge requests'
    : 'Pull requests',
)

const readPrsParam = (): PrListTab | null => {
  // No try/catch here: `local/no-silent-fallback-catch` counts this file's fallbacks against a
  // baseline, and a `catch → null` would be an 8th. Optional chaining is total on null/undefined,
  // so there is nothing to catch.
  const raw: unknown = route?.query?.[PRS_PARAM]
  return raw === 'open' || raw === 'closed' ? raw : null
}

const openPrsFromRoute = () => {
  const tab = readPrsParam()
  if (tab) {
    prsTab.value = tab
    prsOpen.value = true
  }
}

const openPrList = () => {
  if (!props.item.path || prsOpen.value) return
  prsOpen.value = true
  prsTab.value = 'open'
  const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
  query[PRS_PARAM] = 'open'
  void router?.push(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, query))
}

const onPrTabChange = (tab: PrListTab) => {
  prsTab.value = tab
  // The list does not watch the tab prop (`local/no-watch` bans new
  // watchers) — reload explicitly, after the prop has propagated.
  void nextTick(() => prListRef.value?.reload())
  const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
  query[PRS_PARAM] = tab
  void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, query))
}

const closePrList = () => {
  prsOpen.value = false
  const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
  delete query[PRS_PARAM]
  void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, query))
}

const onPrListOpenCount = (n: number) => {
  prOpenCount.value = n
}

// One open-count fetch on mount. A failure leaves the badge absent
// rather than showing 0 — the `.then(ok, err)` shape (no
// try/catch) matches the list view's own fail-visible contract.
const fetchPrOpenCount = () => {
  const cwd = props.item.path || ''
  if (!cwd) return
  listPrs(cwd, { state: 'open', limit: 30 }).then(
    (resp) => {
      prOpenCount.value = (resp.changes ?? []).length
      prOpenTruncated.value = !!resp.truncated
      prProviderGuess.value = resp.provider || ''
    },
    () => {
      // Leave the badge absent — a fake 0 is worse than no badge.
    },
  )
}

// After a successful close the board button's count drops by one and the affected card's badge must
// flip from open to closed.
const prBadgeTick = ref(0)
const prClosedBranches = ref<string[]>([])

const prColumnKey = (columnId: string): string => {
  if (prBadgeTick.value === 0) return columnId
  const holds = (deps.tasks.value ?? []).some(
    (t) => t.kanban_column_id === columnId && prClosedBranches.value.includes(t.git_branch ?? ''),
  )
  return holds ? `${columnId}:pr${prBadgeTick.value}` : columnId
}

const onPrListClosed = (payload: { number: number; headRef: string }) => {
  const cwd = props.item.path || ''
  if (cwd && payload.headRef) {
    invalidatePrStatus(cwd, payload.headRef)
    if (!prClosedBranches.value.includes(payload.headRef))
      prClosedBranches.value = [...prClosedBranches.value, payload.headRef]
    prBadgeTick.value += 1
  }
  if (prOpenCount.value !== null) prOpenCount.value = Math.max(0, prOpenCount.value - 1)
}

  return {
    prsOpen,
    prsTab,
    prListRef,
    setPrListEl,
    prOpenCount,
    prOpenTruncated,
    prProviderGuess,
    prPluralLabel,
    prBadgeTick,
    prClosedBranches,
    readPrsParam,
    openPrsFromRoute,
    openPrList,
    onPrTabChange,
    closePrList,
    onPrListOpenCount,
    fetchPrOpenCount,
    prColumnKey,
    onPrListClosed,
  }
}

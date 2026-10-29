import { computed, nextTick, reactive, ref, type ComputedRef, type Ref } from 'vue'
import type { LocationQueryRaw, RouteLocationNormalizedLoaded, Router } from 'vue-router'
import { useInjectCodeViewer, type CodeViewerView } from '@/composables/useCodeEditor'
import { isChatRouteStaleForSession } from '../../../helpers/appUrl'
import { encodePathParam, scrollToSectionElement } from '../chat_right_sidebar/parseUnifiedDiff'
import type { DiffSelection } from '../chat_right_sidebar/parseUnifiedDiff'

export interface ChatDiffViewDeps {
  router: Router
  route: RouteLocationNormalizedLoaded
  sessionId: Ref<string>
  chatSidebarRef: Ref<{ reloadDiff: () => void } | null>
  centerDiff: Ref<DiffSelection | null>
  centerFiles: Ref<DiffSelection[]>
  currentPath: Ref<string | null>
  centerDiffScrollRef: Ref<HTMLElement | null>
  showCenterDiff: ComputedRef<boolean>
}

export function useChatDiffView(deps: ChatDiffViewDeps) {
  const {
    router,
    route,
    sessionId,
    chatSidebarRef,
    centerDiff,
    centerFiles,
    currentPath,
    centerDiffScrollRef,
    showCenterDiff,
  } = deps

  // ── Centre-diff view state: two axes, one owner ─────────────────────────── mode          — LAYOUT
  // (unified | split). Global, so it lives in the URL (?diffmode=) with a localStorage fallback for
  // "I always read split".
  const DIFF_MODE_STORAGE_KEY = 'pabrik.centerdiff.mode'

  const readStoredDiffMode = (): 'unified' | 'split' => {
    try {
      const stored = localStorage.getItem(DIFF_MODE_STORAGE_KEY)
      if (stored === 'unified' || stored === 'split') return stored
    } catch {
      // No storage (private mode / jsdom) — the documented default stands.
    }
    return 'unified'
  }

  /** Read `?diffmode=` at SETUP time, unlike `syncDiffParam` (a click handler). That makes the read
   * optional-router-safe: ~30 specs mount with no router, where a bare `route.query` would throw
   * inside setup and fail the whole mount. */
  const readDiffModeParam = (): 'unified' | 'split' | null => {
    const v = route?.query?.diffmode
    return v === 'unified' || v === 'split' ? v : null
  }

  const diffMode = ref<'unified' | 'split'>(readDiffModeParam() ?? readStoredDiffMode())
  const collapsedPaths = reactive(new Set<string>())
  const wholeFilePaths = reactive(new Set<string>())

  const collapsedCount = computed(
    () => centerFiles.value.filter((f) => collapsedPaths.has(f.path)).length,
  )
  /** True when every listed file is collapsed — the state ?diffcollapse=1 names. */
  const allCollapsed = computed(
    () => centerFiles.value.length > 0 && collapsedCount.value === centerFiles.value.length,
  )

  /**  * Write one of the diff view's params, skipping stale writes during a chat switch (the same guard
   * `syncDiffParam` needs: ChatsList replaces the URL at the same time, and a second replace from the
   * dying view corrupts the patch). */
  function syncDiffQuery(mutate: (query: LocationQueryRaw) => void) {
    // Same optional-router guard as `syncDiffParam`: a ChatView mounted outside
    // the router tree has no URL to write to.
    if (!route) return
    if (route.query.view !== undefined && route.query.view !== 'chat') return
    const routeSession = route.query.session
    if (typeof routeSession === 'string' && routeSession !== sessionId.value) return
    if (isChatRouteStaleForSession(route.path, sessionId.value)) return
    const query: LocationQueryRaw = { ...route.query }
    mutate(query)
    router.replace({ path: route.path, query }).catch(() => {})
  }

  const syncCollapseParam = () => {
    syncDiffQuery((query) => {
      if (allCollapsed.value) query.diffcollapse = '1'
      else delete query.diffcollapse
    })
  }

  /** Replace-all rather than per-file: the bulk button is one user gesture, and
   * `?diffcollapse=1` can only mean "all of them". */
  function setAllCollapsed(collapsed: boolean, paths: DiffSelection[] = centerFiles.value) {
    collapsedPaths.clear()
    if (collapsed) for (const f of paths) collapsedPaths.add(f.path)
    syncCollapseParam()
  }

  function toggleCollapse(path: string) {
    if (collapsedPaths.has(path)) collapsedPaths.delete(path)
    else collapsedPaths.add(path)
    syncCollapseParam()
  }

  /**  * Whole file is per section — 40 whole-file requests and a wall of text is not what "show me this
   * file" means. The untracked case is refused UP FRONT: a new file's diff already IS the whole file,
   * so the control stays locked at "Whole file" and no request is ever made. */
  function toggleWholeFile(path: string) {
    if (wholeFilePaths.has(path)) wholeFilePaths.delete(path)
    else wholeFilePaths.add(path)
  }

  function setDiffMode(next: 'unified' | 'split') {
    diffMode.value = next
    try {
      localStorage.setItem(DIFF_MODE_STORAGE_KEY, next)
    } catch {
      // Storage unavailable — the URL still carries the choice.
    }
    syncDiffQuery((query) => {
      query.diffmode = next
    })
  }

  /** The code viewer's open file, shared by `AppLayout` (which owns the session). Non-null ⇒ this
   * chat renders the file in its center column, exactly where the stacked center diff goes, so the
   * chat-owned right sidebar — the Explorer the user just clicked a file in — stays on screen. */
  const codeViewer = useInjectCodeViewer()
  /**  * Plain (never-null) view model for the template: the injected session unwrapped, or an empty model
   * when there is no provider (unit tests) / no open file. One object, so the template needs no
   * null-narrowing. */
  const codeViewerModel = computed<CodeViewerView>(() => ({
    file: codeViewer?.file.value ?? null,
    content: codeViewer?.content.value ?? '',
    loading: codeViewer?.loading.value ?? false,
    error: codeViewer?.error.value ?? null,
    line: codeViewer?.requestedLine.value ?? null,
    cwd: codeViewer?.cwd.value ?? '',
    close: () => codeViewer?.close(),
  }))
  const showCodeViewer = computed(() => codeViewerModel.value.file !== null)
  /** Messages + composer are hidden while either center stage is up. */
  const showCenterStage = computed(() => showCenterDiff.value || showCodeViewer.value)

  function scrollToCenterFile(path: string) {
    // Click on an already-loaded file scrolls instead of refetching.
    currentPath.value = path
    if (showCenterDiff.value) syncDiffParam(path)
    // Expand before scrolling: landing on a collapsed section would scroll to a
    // one-line stub and look like the click did nothing.
    if (collapsedPaths.has(path)) {
      collapsedPaths.delete(path)
      syncCollapseParam()
    }
    scrollToSectionElement(path)
  }

  function onChatSidebarShowDiff(selection: DiffSelection) {
    centerDiff.value = selection
    const idx = centerFiles.value.findIndex((f) => f.path === selection.path)
    if (idx >= 0) centerFiles.value[idx] = selection
    else {
      centerFiles.value.push(selection)
      syncCenterSpy()
    }
    void nextTick(() => scrollToCenterFile(selection.path))
  }

  function onChatSidebarShowDiffList(files: DiffSelection[]) {
    // Union by path, incoming list order wins — the panel just fetched
    // everything, so its entries are the freshest.
    const incoming = new Map(files.map((f) => [f.path, f]))
    const merged = [...files]
    for (const existing of centerFiles.value) {
      if (!incoming.has(existing.path)) merged.push(existing)
    }
    centerFiles.value = merged
    syncCenterSpy()
    // A file that arrived WHILE the bulk state was "all collapsed" must arrive
    // collapsed too, or the next poll would silently expand one row.
    if (allCollapsed.value) {
      for (const f of merged) collapsedPaths.add(f.path)
    }
    // Refresh an open selection in place when the list reloads, but never
    // auto-open from a background list load — refresh must land on chat.
    if (centerDiff.value) {
      const refresh = incoming.get(centerDiff.value.path)
      if (refresh) centerDiff.value = refresh
    }
  }

  function onCenterDiffBack() {
    centerDiff.value = null
    centerFiles.value = []
    syncCenterSpy()
    currentPath.value = null
    // Per-file view state dies with the stage, and the bulk param with it.
    collapsedPaths.clear()
    wholeFilePaths.clear()
    syncDiffQuery((query) => {
      delete query.diffcollapse
    })
    stopCenterSpy()
    // Back exits the diff view: drop the param so reload lands on chat,
    // not a stale file. The currentPath watcher skips while hidden, so
    // clear it explicitly here (replace, not push).
    syncDiffParam(null)
  }

  // Scroll-spy: the most-visible section (middle band of the center
  // scroll container) owns currentPath, which syncs to ?diff= below.
  let centerSpy: IntersectionObserver | null = null

  function startCenterSpy() {
    stopCenterSpy()
    const root = centerDiffScrollRef.value
    if (!root || typeof IntersectionObserver === 'undefined') return
    centerSpy = new IntersectionObserver(
      (entries) => {
        // Ignore late callbacks after stop (chat switch unmounts the
        // scroll container mid-navigation; writing currentPath then
        // would fire a stale router.replace racing ChatsList).
        if (!centerSpy) return
        let best: string | null = null
        let bestRatio = 0
        for (const entry of entries) {
          const path = (entry.target as HTMLElement).dataset.path
          if (!entry.isIntersecting || !path) continue
          if (entry.intersectionRatio > bestRatio) {
            bestRatio = entry.intersectionRatio
            best = path
          }
        }
        if (best) {
          currentPath.value = best
          if (showCenterDiff.value) syncDiffParam(best)
        }
      },
      { root, rootMargin: '-40% 0px -55%', threshold: [0, 0.25, 0.5, 0.75, 1] },
    )
    for (const el of root.querySelectorAll('[data-testid="center-diff-section"]'))
      centerSpy.observe(el)
  }

  function stopCenterSpy() {
    centerSpy?.disconnect()
    centerSpy = null
  }

  function syncDiffParam(path: string | null) {
    // No router = nothing to keep in sync. Unit mounts (and any host that renders ChatView outside
    // the router tree) have `useRoute() === undefined`, where a bare `route.query` throws from the
    // currentPath watcher and fails the mount. There is no URL to be stale in that case.
    if (!route) return
    // Skip stale writes during chat switch: ChatsList replaces the URL
    // with the new session at the same time; a second replace from the
    // dying view races it and corrupts Vue's patch (null vnode).
    if (route.query.view !== undefined && route.query.view !== 'chat') return
    const routeSession = route.query.session
    if (typeof routeSession === 'string' && routeSession !== sessionId.value) return
    if (isChatRouteStaleForSession(route.path, sessionId.value)) return
    const query = { ...route.query }
    if (path) query.diff = encodePathParam(path)
    else delete query.diff
    router.replace({ path: route.path, query }).catch(() => {})
  }

  // (The old currentPath watcher lived here — every assignment site below now calls syncDiffParam
  // explicitly. Replace, not push — scrolling must not spam history entries.) Start/stop the
  // scroll-spy to match the file list (replaces the old centerFiles.length watcher).
  const syncCenterSpy = () => {
    if (centerFiles.value.length === 0) stopCenterSpy()
    else void nextTick(() => startCenterSpy())
  }

  function onCenterDiffRetry() {
    chatSidebarRef.value?.reloadDiff()
  }

  return {
    codeViewerModel,
    collapsedCount,
    collapsedPaths,
    diffMode,
    onCenterDiffBack,
    onCenterDiffRetry,
    onChatSidebarShowDiff,
    onChatSidebarShowDiffList,
    setAllCollapsed,
    setDiffMode,
    showCenterStage,
    showCodeViewer,
    stopCenterSpy,
    syncCenterSpy,
    syncDiffParam,
    toggleCollapse,
    toggleWholeFile,
    wholeFilePaths,
  }
}

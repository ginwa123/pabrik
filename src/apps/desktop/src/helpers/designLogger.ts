/**
 * designLogger.ts
 *
 * A focused logger for the design-mode drag/resize wire.
 *
 * Why this exists: when the user drags a group and only the group
 * moves but not its children ("first drag works, second needs
 * refresh"), or when non-group elements don't move, the failure mode
 * is one of:
 *
 *   - useDesignHandlers.translateElement's activeDesignPageId check
 *     fails (no-op, no API call fired)
 *   - The element's pointerdown handler emits `groupDrag` instead of
 *     `translate` (because isGroupLike|inMultiselect test was wrong)
 *   - dragStartPositions Map still has the first drag's baseline
 *     when the second drag fires (handleGroupDrag's
 *     `if (dragStartPositions === null)` check leaked)
 *   - store.translateDesignElement / moveDesignElementsBatch hit
 *     activeDesignPageId empty (silent no-op)
 *   - The SSE handler's `isRecentLocalMutation` Map returned false
 *     and `fetchDesignElements` ran with stale state on top of the
 *     optimistic local mirror
 *
 * Without per-call logs you can't tell WHICH layer broke. The log
 * lines below fire at every key step in the wire (pointerdown,
 * emit, store call, response mirror, SSE receipt) so a single
 * DevTools console scroll answers:
 *
 *   1. Did the element pointerdown fire?
 *   2. Did the right gesture path branch (move-vs-resize-vs-group)?
 *   3. What was the cursor delta?
 *   4. Did the store see the call (with what args)?
 *   5. Did the SSE echo back?
 *   6. Did the local mirror update as expected?
 *
 * Design mirrors scrollLogger.ts (info / warn / error, lazy stack
 * capture on warn+error, caller field, single emit site).
 */

import { ref } from 'vue'

// ─── Configuration ─────────────────────────────────────────────────────────
/** Global logger enable. Default false to keep the production console quiet; flip via the Vue
 * devtools "design logger" toggle (a small boolean stored in localStorage + reactive ref). */
/** We deliberately keep this SEPARATE from `import.meta.env.DEV` — `import.meta.env.DEV` is a
 * build-time constant that locks the decision to "always on in dev, always off in prod". */
/** The design logger is intentionally toggleable at runtime because the bugs it catches
 * (group-cascade race, SSE-dedupe race) happen in production too, and a single `localStorage.dl=on`
 * line gets the diagnostic out the door without a rebuild. */
const STORAGE_KEY = 'pabrik.design-logger.enabled'

const enabledRef = ref<boolean>(false)

// Read from localStorage synchronously at module-load so the first gesture in a fresh page already
// has the right setting. SSR-safe: the typeof check protects against environments where
// localStorage throws.
if (typeof localStorage !== 'undefined') {
  try {
    enabledRef.value = localStorage.getItem(STORAGE_KEY) === 'on'
  } catch {
    // ignore — leave at default
  }
}

// AUTO-ENABLE: a developer-mode browser that has the `__designLogger` escape hatch registered must
// have loaded the new bundle. If the user reloads the page or the `__designLogger` flag wasn't set,
// fall back to "auto on" so they immediately see diagnostics.
// The user can still call `__designLogger.off()` to silence it. This is dev-only. Detection:
// `window.__designLogger` was set by the bottom of this file (the escape hatch install).
// If it's not present, the bundle running is OLD (pre-logger) and the page should auto-enable so
// the next page reload picks up the new bundle. We use a single-shot check at module-load time to
// avoid re-running on every navigation.
if (import.meta.env.DEV && typeof window !== 'undefined') {
  const w = window as unknown as { __designLoggerAlreadyInstalled?: boolean }
  if (!w.__designLoggerAlreadyInstalled && !enabledRef.value) {
    // First load on this origin — turn the logger on by default so
    // the user sees diagnostics immediately. The escape hatch below
    // still allows `__designLogger.off()` to silence it.
    enabledRef.value = true
    if (typeof localStorage !== 'undefined') {
      try {
        localStorage.setItem(STORAGE_KEY, 'on')
      } catch {
        // ignore
      }
    }
  }
}

/** True while the logger is producing console output. */
export const isDesignLoggerEnabled = (): boolean => enabledRef.value

/**
 * Enable/disable at runtime. Writes the new value to localStorage so the setting survives reload. /
 */
export const setDesignLoggerEnabled = (on: boolean): void => {
  enabledRef.value = on
  if (typeof localStorage !== 'undefined') {
    try {
      if (on) localStorage.setItem(STORAGE_KEY, 'on')
      else localStorage.removeItem(STORAGE_KEY)
    } catch {
      // ignore — localStorage might be full or unavailable
    }
  }
}

// ─── Reasons (the most useful field) ────────────────────────────────────────
/** The set of `reason` values the design logger emits. Each one identifies a unique point in the
 * wire — a single DevTools `grep reason=…` isolates a layer. */
/** Naming: a colon-separated path so a search like `reason=drag:start` matches all drag-start
 * events but `reason=drag:start:group` matches only group-drag starts. */
export type DesignReason =
  // ── Element layer (DesignElement.vue) ─────────────────────────────
  | 'drag:start:move'              // pointerdown on a leaf/body, single-element
  | 'drag:start:group'             // pointerdown triggered groupDrag path
  | 'drag:start:resize'            // pointerdown on a resize handle
  | 'drag:noop:readonly'           // gesture blocked by readonly
  | 'drag:noop:preview'            // gesture blocked by preview mode
  | 'drag:noop:button≠0'           // pointerdown with non-primary button
  | 'drag:noop:child-of-group'     // pointerdown on a child element nested inside a parent group/frame (drag suppressed — user must drag the parent)
  | 'drag:throttled-skip'          // onMove fired but throttle suppressed emit
  | 'drag:throttled-emit'          // onMove fired and throttle passed
  | 'drag:trailing-emit'           // pointerup trailing emit (capture final pos)
  | 'emit:select'                  // emit('select', …)
  | 'emit:select:parent-of-child'  // emit('select', parent.id) — child redirect (2026-08-06)
  | 'emit:dragStart'               // emit('dragStart', ids)
  | 'emit:dragEnd'                 // emit('dragEnd')
  | 'emit:translate'               // emit('translate', delta)
  | 'emit:resize'                  // emit('resize', patch)
  | 'emit:groupDrag'               // emit('groupDrag', delta)
  // ── View layer (DesignView.vue) ───────────────────────────────────
  | 'handle:translateElement'      // emit('translateElement', id, dx, dy)
  | 'handle:resizeElement'         // emit('resizeElement', id, patch)
  | 'handle:groupDrag'             // handleGroupDrag fires → designHandlers.moveElementWithDescendants
  | 'handle:dragStart:resetSnapshot' // dragStartPositions = null (the reset on every drag)
  | 'handle:dragEnd:snapshot=null' // handleDragEnd confirmed the reset
  // ── Layout layer (AppLayout) ──────────────────────────────────────
  | 'app:translateElement'         // useDesignHandlers.translateElement entered
  | 'app:resizeElement'            // useDesignHandlers.resizeElement entered
  | 'app:moveWithDescendants'      // useDesignHandlers.moveElementWithDescendants entered
  | 'app:noop:noActivePage'        // silent no-op because activeDesignPageId is empty
  // ── Store layer (workspacesStore) ──────────────────────────────────
  | 'store:translateDesignElement:api' // POST /translate fired
  | 'store:translateDesignElement:mirror' // response mirrored into design_elements[]
  | 'store:resizeDesignElement:api'    // POST /resize fired
  | 'store:resizeDesignElement:mirror' // response mirrored
  | 'store:moveDesignElementsBatch:api' // POST /move-batch fired (group drag)
  | 'store:moveDesignElementsBatch:mirror' // cascade mirrored
  // ── SSE layer (designSse.ts) ──────────────────────────────────────
  | 'sse:received'                  // incoming design event, before dedupe
  | 'sse:dedupe-hit'                // event was local — skipped the GET
  | 'sse:dedupe-miss'              // event came from elsewhere — re-fetched
  // ── Fetch layer ───────────────────────────────────────────────────
  | 'fetch:response'                // incoming GET page returned N elements
  | 'fetch:in-place-mirror'         // existing array mutated (Vue reactivity preserved)
  | 'fetch:replaced-array'          // array reference replaced (the OLD bug)

// ─── Context (the per-line state snapshot) ────────────────────────────────

export interface ElementInfo {
  id: string
  type: string
  x: number
  y: number
  width: number
  height: number
  parentId: string
}

export interface DesignContext {
  /**    * Which component / function produced this log line — without it, `drag:start:move` from
   * `DesignElement.vue` looks identical to `drag:start:move` from anywhere else. */
  caller: string

  /** Stable reason code (see `DesignReason`). */
  reason: DesignReason

  // ── Drag gesture state ────────────────────────────────────────────
  /** The element being interacted with (pointerdown target). Always
   * populated for drag:* reasons. */
  element?: ElementInfo
  /** Cursor delta in design-px (zoom-adjusted). For drag:throttled-emit /
   * drag:trailing-emit / emit:translate / emit:groupDrag. */
  dx?: number
  dy?: number
  /**
   * Resize patch (absolute geometry). For emit:resize.
   */
  patch?: Partial<{ x: number; y: number; width: number; height: number; rotation: number }>
  /**    * startClientX/Y captured at pointerdown — without these, a 5px discrepancy in a delta looks like
   * "wait, where did the extra 5 come from?". */
  startClientX?: number
  startClientY?: number
  /**    * True iff this gesture branched into triggerGroupDrag (group / frame / multi-select move). The
   * single most useful invariant — `drag:start:group=true` vs `false` tells you which wire fired. */
  isGroup?: boolean
  /**    * Whether the start fired dragStartPositions = null (the reset on every drag). Lets us
   * distinguish "this drag has a clean baseline" (`fresh=true`) from "we reused the previous drag's
   * baseline" (`fresh=false` — the suspected second-drag bug). */
  snapshotFresh?: boolean
  snapshotSize?: number

  // ── Network args ─────────────────────────────────────────────────
  endpoint?: string                     // '/translate' | '/resize' | '/move-batch' | …
  /** Workspace/item/page triple (where the API is going). */
  workspaceId?: string
  itemId?: string
  pageId?: string
  /** True when activeDesignPageId was empty at call site. */
  noActivePage?: boolean
  /** Mirror target ids — used to count cascade expansion. */
  ids?: string[]
  /** Returned array length (response mirror). */
  mirrorCount?: number

  // ── SSE ──────────────────────────────────────────────────────────
  sseEventType?: string
  /** ids found in the SSE event payload. */
  sseEventIds?: string[]
  /** Decision: "skip" if dedupe hit, "fetch" if miss. */
  sseDecision?: 'skip' | 'fetch'

  // ── Free-form ─────────────────────────────────────────────────────
  extra?: Record<string, unknown>

  /** Lazy stack trace — captured on warn/error by emit() only. */
  stack?: string
}

// ─── Throttling ────────────────────────────────────────────────────────────
/**  * Drag pointermoves fire at 60+ Hz. Without throttling, the `drag:throttled-emit` lines would flood
 * the console. Coalesce them to the most recent per-gesture-id, flushing 200 ms after the last
 * fired (trailing edge so the final position is never lost). */
const DEBUG_THROTTLE_MS = 200

interface PendingEmit {
  ctx: DesignContext
  level: 'debug' | 'info' | 'warn' | 'error'
  timer: ReturnType<typeof setTimeout> | null
}

const pendingByKey: Map<string, PendingEmit> = new Map()

const flushKey = (key: string): void => {
  const p = pendingByKey.get(key)
  if (!p) return
  if (p.timer) clearTimeout(p.timer)
  pendingByKey.delete(key)
  emitInternal(p.ctx, p.level)
}

// ─── Public surface ────────────────────────────────────────────────────────

export interface DesignLogger {
  debug: (ctx: Omit<DesignContext, 'caller' | 'reason'> & { reason: DesignReason; caller?: string }) => void
  info: (ctx: Omit<DesignContext, 'caller' | 'reason'> & { reason: DesignReason; caller: string }) => void
  warn: (ctx: Omit<DesignContext, 'caller' | 'reason'> & { reason: DesignReason; caller: string }) => void
  error: (ctx: Omit<DesignContext, 'caller' | 'reason'> & { reason: DesignReason; caller: string }) => void
}

/** Singleton. The design-mode wire has no per-chat-id scoping (one
 * design canvas at a time), so a single global logger suffices. */
export const designLogger: DesignLogger = {
  debug(partial) {
    const ctx = { ...partial, caller: partial.caller ?? 'unknown' } as DesignContext
    // Throttle per (caller|reason|element.id) key. Group drag fires
    // ~20 emits/sec; we want ~5.
    const key = `${ctx.caller}|${ctx.reason}|${ctx.element?.id ?? '_'}`
    const existing = pendingByKey.get(key)
    if (existing) {
      existing.ctx = ctx
      if (existing.timer) clearTimeout(existing.timer)
      existing.timer = setTimeout(() => flushKey(key), DEBUG_THROTTLE_MS)
      return
    }
    const timer = setTimeout(() => flushKey(key), DEBUG_THROTTLE_MS)
    pendingByKey.set(key, { ctx, level: 'debug', timer })
  },
  info(partial) {
    const ctx = { ...partial } as DesignContext
    emitInternal(ctx, 'info')
  },
  warn(partial) {
    const ctx = { ...partial } as DesignContext
    emitInternal(ctx, 'warn')
  },
  error(partial) {
    const ctx = { ...partial } as DesignContext
    emitInternal(ctx, 'error')
  },
}

// ─── Console escape hatch ──────────────────────────────────────────────────
// When `import.meta.env.DEV` is true, expose a `window.__designLogger`
// so the user can toggle from DevTools without rebuilding:
//   __designLogger.on()    // enable
//   __designLogger.off()   // disable
//   __designLogger.status() // is it on?
// Production builds skip this entirely (so the toggle is dev-only).
if (import.meta.env.DEV && typeof window !== 'undefined') {
  (window as unknown as { __designLogger: unknown }).__designLogger = {
    on: () => setDesignLoggerEnabled(true),
    off: () => setDesignLoggerEnabled(false),
    status: () => isDesignLoggerEnabled(),
  }
}

// ─── Emit ──────────────────────────────────────────────────────────────────

let eventCounter = 0

const emitInternal = (ctx: DesignContext, level: 'debug' | 'info' | 'warn' | 'error'): void => {
  if (!enabledRef.value) return

  eventCounter += 1
  const tag = `[design#${eventCounter} ${ctx.caller} ${level.toUpperCase()}] ${ctx.reason}`

  // ── Compact one-liner with the most useful fields ───────────────
  const drag = ctx.dx !== undefined || ctx.dy !== undefined
    ? ` dx=${ctx.dx ?? 0},dy=${ctx.dy ?? 0}`
    : ''
  const resize = ctx.patch
    ? ` patch=${JSON.stringify(ctx.patch)}`
    : ''
  const startMark = ctx.startClientX !== undefined
    ? ` start=(${ctx.startClientX},${ctx.startClientY ?? '?'})`
    : ''
  const snapMark = ctx.snapshotSize !== undefined
    ? ` snapshot=${ctx.snapshotFresh ? 'fresh' : 'STALE'}(${ctx.snapshotSize})`
    : ''
  const groupMark = ctx.isGroup !== undefined
    ? ` isGroup=${ctx.isGroup}`
    : ''
  const noPageMark = ctx.noActivePage ? ' ⚠NO_ACTIVE_PAGE' : ''
  const endpointMark = ctx.endpoint ? ` → ${ctx.endpoint}` : ''
  const ids = ctx.ids ? ` ids=[${ctx.ids.slice(0, 3).join(',')}${ctx.ids.length > 3 ? `,…+${ctx.ids.length - 3}` : ''}]` : ''
  const mirror = ctx.mirrorCount !== undefined ? ` mirror=${ctx.mirrorCount}` : ''
  const sse = ctx.sseEventType
    ? ` sse=${ctx.sseEventType}${ctx.sseDecision ? `:${ctx.sseDecision}` : ''}${ctx.sseEventIds ? ` ids=[${ctx.sseEventIds.join(',')}]` : ''}`
    : ''

  const ids_ = ctx.workspaceId || ctx.itemId || ctx.pageId
    ? ` ws=${ctx.workspaceId ?? '?'},item=${ctx.itemId ?? '?'},page=${ctx.pageId ?? '?'}`
    : ''

  // Element display — when present, helps correlate the line to the
  // element the user is interacting with.
  const el = ctx.element
    ? ` el=${ctx.element.id}(${ctx.element.type},${ctx.element.parentId || 'top'}@${ctx.element.x},${ctx.element.y})`
    : ''

  const line1 =
    `${tag}${el}${drag}${resize}${startMark}${snapMark}${groupMark}` +
    `${noPageMark}${endpointMark}${ids_}${ids}${mirror}${sse}`

  // ── Lazy stack capture on warn+error ─────────────────────────────
  if (!ctx.stack && (level === 'warn' || level === 'error')) {
    try {
      const err = new Error()
      const frames = (err.stack ?? '')
        .split('\n')
        .filter((line) => !line.includes('designLogger.ts'))
        .slice(0, 5)
        .join('\n')
      if (frames) ctx.stack = frames
    } catch {
      // stack capture is best-effort; never let it break logging
    }
  }

  if (level === 'error') console.error(line1, ctx)
  else if (level === 'warn') console.warn(line1, ctx)
  else console.log(line1, ctx)
}

// ─── Helpers for callers ───────────────────────────────────────────────────
/**  * Convert a DesignElement into the compact ElementInfo shape the logger prefers. Avoids passing 30+
 * fields when only 5 are useful for diagnostic output. */
export const abbrevElement = (e: {
  id: string
  type: string
  x: number
  y: number
  width: number
  height: number
  parent_id?: string | null
}): ElementInfo => ({
  id: e.id,
  type: e.type,
  x: e.x,
  y: e.y,
  width: e.width,
  height: e.height,
  parentId: e.parent_id ?? '',
})

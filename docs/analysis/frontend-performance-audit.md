# Frontend performance audit — 2026-10-22

Task: *"i think performance chatview much more slower audit that, or maybe another component ?"*

Everything below is either **measured** (a command whose output is reproducible, quoted inline) or
**verified by reading** the cited line. Nothing is estimated from vibes; where a number could not be
obtained the text says so.

Method: `vite build` for bundle facts, and `vite-node` / `vitest` micro-benchmarks against the real
helper modules for per-call costs. Benchmarks ran on Node 24 / V8 — the shipping runtime is
WebKitGTK's JSC, which is typically **slower**, so treat these as a floor.

---

## Ranked: what is actually slow

| # | finding | where | measured cost | fixed here |
|---|---|---|---|---|
| 1 | Every streaming delta re-parses the whole answer as markdown | `helpers/renderResponse.ts:25,88` | **1.68 ms** per 32 KB answer, **667 misses** per stream ≈ **1.1 s** of markdown CPU per answer | partly (cache no longer destroyed) |
| 2 | One streaming answer evicts the whole transcript's rendered-HTML cache | `renderResponse.ts:68` (`cache.clear()`) | cache **hit is 544x cheaper** than a miss — and every visible row became a miss every 200 chunks | yes |
| 3 | Tool-card sub-agent lookup walks back to the transcript start, `JSON.parse` on each assistant message | `ChatView.vue:1574,1674` → `parseSpawnSubAgentArgs.ts:22` | **0.26 ms/card** @1 KiB envelopes, **1.03 ms/card** @10 KiB (200 turns); **1.31 ms per render** for 5 cards in view | no — documented below |
| 4 | No route-level code splitting: 12 routes → one static `AppLayout` → 27 static imports | `router/index.ts:2,25-96`; `AppLayout.vue:4-31` | entry chunk **2,086,120 B raw / 545,210 B gz**; whole app 7.2 MB raw / 2.0 MB gz over 119 chunks | no — documented below |
| 5 | Debug log objects built on the render/measure hot path in production | `VirtualScroller.vue:222-249,553-587` | 4 forced layout reads inside the `sizerHeight` **computed** (i.e. during render) + 5 in every compensation pass | yes |
| 6 | Per-chunk `console.log` of the full streamed answer and of every SSE event | `ChatView.vue:3003,3352,3255,3275` (pre-fix) | one retained copy of a growing string per chunk; also `console.log` inside the `currentView` computed (`AppLayout.vue:945-984`) | yes |
| 7 | Rich-block turns bypass the markdown cache entirely | `ChatView.vue:4172` (`marked.parse` inline in the template) | same 1.68 ms/32 KB figure, paid on **every render** of any turn containing `<html>`/`<mermaid>` | yes |
| 8 | Layout-reading pollers that never stop | `ChatScrollSlider.vue:200` (500 ms), `TerminalFooter.vue:357` (15 s), `ChatView.vue:1358` + `FolderExplorer.vue:100` (duplicate 30 s git polls) | 2 layout-reading wakeups/s per open chat + a `/api/shell` round-trip every 15 s app-wide | no — documented below |
| 9 | A full-screen settings overlay does not unmount the view underneath | `AppLayout.vue:2903,2908`; `SettingsShell.vue:152` (`fixed inset-0 z-50`) | the previous view's timers, pollers and scrollers keep running behind an opaque page | no — documented below |

## Measured, and NOT a problem (so nobody re-investigates)

| candidate | measured |
|---|---|
| `hasRichBlocks` in the template (`ChatView.vue:4164`) | **0.004 ms** per 32 KB |
| `extractRichBlocks` in the template (`ChatView.vue:4166`) | **0.005 ms** per 32 KB |
| `stripThinkingTags` over a whole 32 KB stream (all 667 misses) | **23.5 ms** total |
| `VirtualScroller` per-pass JS cost in jsdom | uninformative — jsdom has no layout, so `measureItems` took its no-change early return. Not used as evidence. |

---

## 1 + 2. The streaming markdown re-parse

`renderResponse` memoises on `role|toolName|content.trim()`. A streaming row's content is a **new
string on every delta**, so every delta is a cache miss and `marked.parse` runs over the whole
accumulated answer. The cost is therefore quadratic in answer length.

```
renderResponse MISS,  1000 B answer    0.215 ms/op   ->  21 chunks =   5 ms of CPU
renderResponse MISS,  4000 B answer    0.351 ms/op   ->  84 chunks =  29 ms
renderResponse MISS, 16000 B answer    1.111 ms/op   -> 334 chunks = 371 ms
renderResponse MISS, 32000 B answer    1.679 ms/op   -> 667 chunks = 1120 ms
renderResponse HIT,   32000 B answer   0.003 ms/op   -> hit/miss ratio: 544x
```

Compounding it: `if (cache.size >= MAX_CACHE_ENTRIES) cache.clear()` (`renderResponse.ts:68`). One
32 KB answer inserts 667 entries, so the cache is wiped **three times** during that answer — and each
wipe turns every other visible row into a re-parse on the next render.

**Shipped fix.** Two changes to `renderResponse.ts`:

- `cache.clear()` → LRU eviction of the single oldest entry (`cacheGet` refreshes recency, `cacheSet`
  evicts one). A stream can no longer destroy the settled transcript's cache.
- `renderStreamingResponse(content, role, tool)` — a dedicated single-slot memo for the one row that
  is streaming, so its per-delta churn does not enter the shared cache at all.

This does not make one parse cheaper. It stops *one* slow row from making *the whole transcript*
slow, which is the part that grows with conversation length.

**Not shipped (needs a visual check):** rendering the streaming row incrementally — cache the parse
of a "sealed" prefix (ends at a blank line, fences balanced) and re-parse only the live tail. That is
the change that removes the quadratic term, but markdown is context-sensitive across a boundary
(`<html>` blocks, tables, lists), so it needs a real browser to verify it never flashes broken
markup. Left as the next step, not guessed at.

## 3. The tool-card backward walk

`toolCardsFor` (`ChatView.vue:1574`) is called **from the template** (`:4104`) so it re-runs on every
render, once per rendered tool group. It calls `findSubAgentArgsForToolGroup` (`:1674`) **per card**,
which walks backwards to group 0 and calls `parseSpawnSubAgentArgs` → `JSON.parse(tool_calls_json)`
(`parseSpawnSubAgentArgs.ts:22`) on every assistant message it passes. `tool_calls_json` for a
`write_file`/`edit` call contains the whole file body, so it is not a small parse.

```
tool_calls_json   1 KiB ->  1.4 us per call
tool_calls_json  10 KiB ->  6.8 us per call
tool_calls_json  50 KiB -> 22.0 us per call

one card, 200 turns of history, 1 KiB  -> 0.26 ms
one card, 200 turns of history, 10 KiB -> 1.03 ms
5 cards in view, 200 turns            -> 1.31 ms per render  (26-78 ms/s at 20-60 renders/s)
```

This is the cost that makes a long chat feel worse than a new one — it is linear in history per card.

**Recommended fix (not shipped).** `Message` objects are stable identities (`mergeMessagesById`
reuses them), so the parse can be memoised per message with a `WeakMap<Message, ParsedCalls>` and
`parseSpawnSubAgentArgs` refactored to take the message rather than the JSON string. The backward
walk then costs only map hits. A forward-built `Map<toolCallId, SubAgentArgs[]>` would be wrong here:
`messageGroups` is invalidated on every delta, so it would rebuild per chunk.

## 4. Bundle: there is no code splitting at all

`router/index.ts` gives all twelve `/app*` routes the **same statically imported** `AppLayout`, and
`AppLayout.vue:4-31` statically imports 27 components (ChatView 5,426 lines, DesignView 2,040,
KanbanView 1,788, …). There is no `defineAsyncComponent` and no `() => import()` for any view.

```
entry index-*.js : 2,086,120 B raw / 545,210 B gz   (one chunk, before first paint)
entry chain      : 2,139,393 B raw / 564,365 B gz   (+ modulepreloaded siblings)
whole app        : 7,200,306 B raw / 2,017,802 B gz over 119 chunks
entry CSS        :   138,173 B
```

`xterm`, `marked` and `effect` are all in that entry chunk; `TerminalFooter` (always mounted) is what
drags `@xterm/xterm` (and its CSS) onto the landing page. `mermaid` and `idb` are correctly lazy.

**Recommended fix (not shipped).** `defineAsyncComponent` for the views behind `<main>`, then gate
`TerminalFooter` on `open`. This changes load timing across the whole shell and needs a real
browser, so it is a separate PR — but it is the single biggest structural win available.

## 5. Debug logging is live in production

`vsLogger` is a `computed` that is non-null whenever the `debugChatId` prop is set
(`VirtualScroller.vue:85`), and ChatView always sets it (`ChatView.vue:3956`). `scrollLogger.ts:309`
gates the *output* on `import.meta.env.DEV` — but the caller builds the argument object **first**,
and building it performs forced layout reads:

- `VirtualScroller.vue:222-249` — inside the `sizerHeight` **computed**, i.e. during render:
  `scrollTop`, `scrollHeight`, `clientHeight`, `offsetHeight`.
- `VirtualScroller.vue:553-587` — inside `measureItems`, the hot path: `scrollHeight`, `clientHeight`,
  `offsetHeight`, `offsetParent`, plus a second `reachableScrollTop()`.

**Shipped fix.** Both blocks are now `if (import.meta.env.DEV && vsLogger.value)`, so production
pays nothing for a log it discards.

## 6. Console noise on the per-chunk path

Removed (all were unconditional `console.log`, one of them printing the entire accumulated answer
once per delta):

- `ChatView.vue:3352` — `streamingContent` per chunk
- `ChatView.vue:3003` — every SSE event, with the whole event object
- `ChatView.vue:3255` — every reasoning delta
- `ChatView.vue:3275` — every queue event
- `ChatView.vue` — SSE connect / error-card / duplicate-event chatter
- `AppLayout.vue:945,950,953,984` — inside the `currentView` computed, so per recompute
- `AppLayout.vue:629` — `handleNavigate`

`console.error`/`console.warn` in real failure paths were left alone. 287 `console.*` calls remain in
non-test source; the ones removed were the ones on a per-chunk or per-render path.

## 7. Rich-block turns bypass the cache

For any turn containing `<html>` or `<mermaid>`, prose segments are rendered by
`v-html="marked.parse(seg.payload, { async: false })"` (`ChatView.vue:4172`) — outside
`renderResponse` and therefore un-memoised, on every render, forever.

**Shipped fix.** `renderMarkdown(payload)` in `renderResponse.ts`: the same `marked.parse` behind the
same LRU cache under a `md|` key prefix (verified not to collide with the message-envelope path —
`renderResponse` unwraps `<think>`/`<markdown>` while `renderMarkdown` must not).

## 8 + 9. Background work worth a follow-up

Verified by reading, not measured:

- `ChatScrollSlider.vue:200` — `setInterval(ensureAttached, 500)` for the whole life of every mounted
  ChatView; when the container is unchanged it calls `readAndApply()` (layout reads). 2/sec/chat.
- `TerminalFooter.vue:357` — `/api/shell` every 15 s app-wide regardless of whether the terminal is
  open.
- `ChatView.vue:1358` and `FolderExplorer.vue:100` — two independent 30 s git-status polls on the same
  endpoint while a chat is open.
- `AppLayout.vue:2903,2908` — `SettingsView` / `WorkspaceSettingsView` are **siblings** of `<main>`,
  and nothing clears the active workspace item on either route, so a kanban/design/chat view stays
  mounted and live behind `SettingsShell`'s `fixed inset-0 z-50`. Its timers keep firing.
- Dead code (0 cost today, listed so nobody "optimises" it): `git/GitChanges.vue`,
  `shell/RightSidebar.vue`, `helpers/frontendLogClient.ts`, `stores/counter.ts` — imported by nobody.

---

## How each number was produced

```bash
cd src/apps/desktop && pnpm install --frozen-lockfile   # 1.3 s from the pnpm store
npx vite build                                          # bundle sizes from dist/assets
npx vite-node <bench>.mts                               # per-call ms against the real helpers
```

The two benchmark scripts were throwaway and are not committed. The behaviour they justified is
pinned by `src/__tests__/renderResponseCache.spec.ts`.

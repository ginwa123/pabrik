# ChatView: cache-first paint vs. the remote half — where the skeleton belongs

**Task:** *"when open chatview we load cache first and after that remote right? how if
we add skeleton loading placeholder if fetch remote still loading"*
**Branch:** `worktree/when-open-chatview-we-load-cache-first-and-after-t-1791889249370`
**Base:** `origin/main` @ `884efc51`

## 1. The answer to the question

**Yes — cache first, then remote.** `runHistoryLoadAttempt` in
`src/apps/desktop/src/components/views/ChatView.vue` is the one attempt body, and it
has two halves:

| | what runs | how long |
|---|---|---|
| **local half** | `chatEngineDb.primeFromCache(sid, PAGE_SIZE)` — an IndexedDB read of rows already written by a previous mount | ~ms |
| **remote half** | cache hit → `chatEngineDb.loadDelta(sid, PAGE_SIZE, liveMessageIds)` (tail only, `cursor` + `asc`)<br>cache miss → `api.fetchChatHistoryEffect(sid, PAGE_SIZE, undefined, 'desc', INITIAL_HISTORY_TIMEOUT_MS)` (authoritative full page) | ms…45 s, ×4 attempts across the retry schedule |

On a **cache hit** the cached rows paint immediately, `isLoading.value = false` is set,
the view scrolls to the bottom, and *then* the delta is awaited. On a **cache miss** the
code falls through to the full page.

**And the skeleton you are picturing already exists — for the half that needs it.**
`data-testid="chat-initializing-skeleton"` is gated on `isInitializing`:

```ts
// BEFORE
const isInitializing = computed(
  () =>
    !isPendingSession.value &&
    (!sessionId.value || (isLoading.value && messages.value.length === 0)),
)
```

- **Cold mount (nothing cached):** `messages` is empty for the whole network page, so
  the skeleton is up for the entire remote fetch — retries included. Which is the
  requirement, and it is the reason `INITIAL_HISTORY_TIMEOUT_MS` is 45 s and
  `chatHistoryRetry.ts` exists ("a long wait costs the user nothing but a skeleton —
  which is exactly the honest representation of 'we asked the server and it hasn't
  answered yet'").
- **Warm mount (cache hit):** the cached rows are on screen, so the skeleton comes down
  the instant they paint and the tail refresh runs *behind real content*.

That last behaviour is correct and worth keeping. This repo already treats a
content-replacing spinner as a defect: the PR #859 skeleton scan lists
`SidebarDiffPanel.vue` — "on refresh the list is REPLACED by spinner (v-if chain) →
full-content flash on every 30 s PR poll" — as a bug, and the cache-first SWR precedent
for the branch chip (`gitStatusCache.ts`, PR #589) revalidates **silently, with no TTL
and no indicator**. Putting a skeleton over a painted transcript would blank real
messages for a ~100 ms window on every chat open.

So the honest version of "add a skeleton while the remote is still loading" is: **show it
exactly when the reader has nothing to look at, and never over content.** Two changes
make that true — because today there is a window where that is *not* what happens.

## 2. The bug this fixes

`messages.length > 0` is not the same thing as "something is on screen". The transcript
renders `messageGroups`, which filters twice:

- `filteredMessages` (`ChatView.vue`) drops a message with a blank stripped content, no
  images, no reasoning and `finish_reason !== 'tool_calls'`;
- `hasBubbleContent` drops an assistant group with no tool header, no reasoning and no
  visible content.

So a cache holding **only unrenderable rows** — an assistant turn whose content never
landed, a tool row the renderer does not know — produces `messages.length === 1` with
`messageGroups.length === 0`. On that mount, before this change:

1. the cache paints, `isLoading = false` → `isInitializing` is **false** (it only looked
   at `messages.length`), so the skeleton comes down;
2. the `<VirtualScroller>` is gated on `!isInitializing && (isLoading || messageGroups.length > 0)`
   → **false**, so no transcript;
3. the empty state is gated on `historyConfirmed` → **false** while the delta runs;
4. `error` is null.

Nothing renders: the transcript area is a **blank column** for the whole delta window.
Then the cache branch set `historyConfirmed = true` ("painted rows exist either way"),
the delta brought nothing renderable either, and the view printed **"How can I help
you?" over a session full of messages** — the exact failure
`task_1790618481206_7` ("if server is slow, keep await, don't show a like this… the
reality is ss i showup is session that not empty the chat messages") and PR #719 fixed
for the *network* path.

## 3. The change

Three edits, one file.

**(a) The readgate asks the right question.** `isInitializing` is now built on an
explicit "the network half is still outstanding" flag and on *what can render*, not on
`messages.length`:

```ts
// new state
const isRemoteLoadPending = ref(false)

// AFTER (declared next to `messageGroups`, which it reads — see the TDZ note below)
const isInitializing = computed(
  () =>
    !isPendingSession.value &&
    (!sessionId.value || (isRemoteLoadPending.value && messageGroups.value.length === 0)),
)
```

`isRemoteLoadPending` is set in `loadChatHistory` and cleared in the `Effect.ensuring`
that already clears `isLoading` — i.e. it tracks the *whole* retry schedule, so the
skeleton cannot flicker out between attempts. Note the flag is **not** what keeps the
warm path fast: `messageGroups.length > 0` short-circuits it, which is why a cached
mount still paints instantly and a cold mount still holds the skeleton.

**(b) The cache branch only confirms emptiness when something actually renders:**

```ts
if (messageGroups.value.length > 0) {
  historyConfirmed.value = true
  setupCodeBlockCopyButtons()
  void rehydrateSubAgentProgress()
  return
}
// else: fall through to the authoritative full page below
```

A cache that cannot answer no longer *claims* the session is empty. Falling through
costs one extra request in a case where an extra request is the only way to know
anything, and `isRemoteLoadPending` keeps the skeleton up across it.

**(c)** the `isInitializing` comment and the skeleton's template comment now describe
this contract instead of the old one.

### TDZ note

`isInitializing` moved from the state block to just below `messageGroups`. It reads
`messageGroups`, which is built from `filteredMessages` (`ChatView.vue`) and
`hasBubbleContent` (`ChatView.vue`) — all `const`s declared further down the file, so a
computed defined above them would hit a temporal-dead-zone `ReferenceError` the first
time it is read. `isInitializing` is read only from the template, so nothing in the
script needed it earlier.

## 4. What was deliberately NOT done

**A skeleton over cached content.** See §1 — the repo's own precedent revalidates
silently, and blanking painted messages on every chat open is a worse trade than a
moment of un-signalled staleness. If a *visible* "still syncing" affordance is wanted for
the warm path, it should be a delayed, non-blocking hint (show only after the revalidation
has been outstanding for a few hundred ms, never over content) — worth its own task,
not this one.

## 5. Verification

**New behavioural spec:** `src/apps/desktop/src/__tests__/views/ChatView.cacheFirstRemoteLoad.spec.ts`
(5 tests). It mocks the two real seams with hoisted `vi.mock` factories — `chatEngineDb`
(so the cache prime and the delta are controllable) and `api.fetchChatHistoryEffect` —
because `vi.spyOn(api, 'getChatHistory')` reaches neither.

| test | asserts |
|---|---|
| cache miss (cold) | skeleton up while the page is in flight; `fetchPageCalls === 1`; no scroller. Control: releasing the page takes the skeleton down and paints the row |
| cache hit, renderable rows | cached transcript + `.virtual-scroller` mounted, **no skeleton**, `loadDeltaCalls === 1`, and **`fetchPageCalls === 0`** (cache-first does not re-fetch the whole page behind the reader) |
| cache hit, renderable rows, delta settles | same, and the transcript survives |
| cache hit, unrenderable rows | skeleton **up**, `loadDeltaCalls === 1` **and `fetchPageCalls === 1`** (the fall-through), then the authoritative row paints |
| cache hit, unrenderable rows + empty page | skeleton (not "How can I help you?") until the server answers; the empty state appears only after the server says so |

**Mutation-tested** — the fix was reverted in two ways and the suite re-run:

- both halves reverted → tests 4 and 5 fail;
- only the `historyConfirmed` gate reverted → tests 4 and 5 fail.

The other three pass either way, as they should: they pin behaviour that was already
correct (the cold path and the cache-first paint).

**Pre-existing red spec repaired:** `src/__tests__/ChatView.initializing.spec.ts` was
red on `main` — 1 passed / **2 failed** — because it drove the load with
`vi.spyOn(api, 'getChatHistory')`, the dead seam, so the real `fetchChatHistoryEffect`
hit the network and the load never settled. It now uses the hoisted `vi.mock` seam and
collapses the retry backoff (via a mock of `helpers/chatHistoryRetry`, whose policy has
its own spec) so the exhausted-retry path is reachable in milliseconds. **3 passed.**

**Gates:** `vue-tsc --build` clean; `oxlint .` 0 warnings / 0 errors; `eslint .` clean;
`prettier --check` clean on the two spec files. `ChatView.vue`'s single remaining
prettier nit is pre-existing (verified against `git show HEAD:…`).

**Regression proof** — JSON-reporter failure lists diffed against a detached worktree at
`HEAD`:

| shard | baseline | this branch |
|---|---|---|
| `src/__tests__/views` | — | 7 files / 22 tests, all pass |
| `src/components/views/__tests__` | 49 files / 341 tests, 3 failed | identical, 3 failed — **0 regressions** |
| the 12 root-level `ChatView*` specs | 8 failed | 6 failed — **2 fixed, 0 regressions** |

The 3 remaining failures (`ChatView.centerDiff`, `ChatView.centerSync`,
`ChatView.tool-width`) fail identically on a clean `HEAD` checkout and are untouched by
this change.

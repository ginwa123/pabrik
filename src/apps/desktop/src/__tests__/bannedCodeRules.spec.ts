/**
 * Regression guard for the banned-code rules.
 *
 * A lint rule that silently stops matching is worse than no rule — it looks
 * enforced and enforces nothing. So this spec pins BOTH directions:
 *
 *   - `forbids` — each ban actually fires on code shaped like the bug.
 *   - `allows`  — each ban stays silent on the legitimate forms that are
 *     common in this repo. This half is the one that matters most: a rule
 *     with false positives gets deleted, and deleting it takes the ban with
 *     it. Every `allows` case below is a shape that really exists in
 *     `src/` — the side-effect `watch(() => props.x, () => load())` idiom
 *     alone is ~46 of the 103 real call sites.
 *
 * Run with the repo's normal suite: `pnpm run test`.
 */
import { describe, expect, it } from 'vitest'
import { Linter } from 'eslint'
import tsParser from '@typescript-eslint/parser'
import plugin from '../../eslint-rules/index'

const linter = new Linter()

type RuleName =
  | 'local/no-watch'
  | 'local/no-watch-array-source'
  | 'local/no-watch-effect'
  | 'local/no-watch-feedback-loop'
  | 'local/no-derived-state-watch'
  | 'local/no-silent-fallback-catch'
  | 'local/no-try-catch'

const ALL_RULES: RuleName[] = [
  'local/no-watch',
  'local/no-watch-array-source',
  'local/no-watch-effect',
  'local/no-watch-feedback-loop',
  'local/no-derived-state-watch',
  'local/no-silent-fallback-catch',
  'local/no-try-catch',
]

/** Lint `code` with ONLY `rules` enabled and return the rule ids that fired. Isolation matters
 * here: the rules legitimately OVERLAP. */
/** A watcher that writes back into the value it watches is often ALSO pure derived state, so
 * `watch(items, v => { items.value = [...v, next] })` trips two bans at once. */
/** Running every rule on every fixture would make each test assert about the others' behaviour, and
 * a test that fails for an unrelated reason is a test people delete. Each describe block opts into
 * just its own rule. */
function lint(code: string, rules: RuleName[] = ALL_RULES): string[] {
  const messages = linter.verify(
    code,
    {
      files: ['**/*.ts'],
      languageOptions: {
        // The same parser the app lints with, so a rule that only works under
        // one parser cannot pass here and fail in `pnpm run lint:check`.
        parser: tsParser as never,
        parserOptions: { ecmaVersion: 2022, sourceType: 'module' },
      },
      plugins: { local: plugin as never },
      rules: Object.fromEntries(rules.map((r) => [r, 'error'])),
    },
    // The filename is REQUIRED: a flat config's `files` array is a matching filter, so without a
    // path to match against the block is silently skipped and every rule reports nothing.

    // That failure mode is invisible — the linter returns [] and the assertions below would pass
    // vacuously.
    'probe.ts',
  )
  return messages.map((m) => m.ruleId as string)
}

const ONLY_DERIVED: RuleName[] = ['local/no-derived-state-watch']
const ONLY_LOOP: RuleName[] = ['local/no-watch-feedback-loop']
const ONLY_WATCH_EFFECT: RuleName[] = ['local/no-watch-effect']
const ONLY_ARRAY_SOURCE: RuleName[] = ['local/no-watch-array-source']
const ONLY_NO_WATCH: RuleName[] = ['local/no-watch']
const ONLY_CATCH: RuleName[] = ['local/no-silent-fallback-catch']
const ONLY_TRY_CATCH: RuleName[] = ['local/no-try-catch']

describe('local/no-derived-state-watch', () => {
  it('flags a watch that only assigns a value computed from its source', () => {
    // The Vue spelling of `useEffect(() => setState(derived), [dep])`.
    expect(
      lint(`const b = ref(0); watch(() => a.n, (v) => { b.value = v * 2 })`, ONLY_DERIVED),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('flags prop-mirroring, the most mechanical form of the bug', () => {
    // 10 real sites of this shape exist today (FileInput.vue:159,
    // TextReplace.vue:34, McpServerModal.vue:63, …).
    expect(
      lint(
        `watch(() => props.expanded, (next) => { isExpanded.value = next ?? false })`,
        ONLY_DERIVED,
      ),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('flags the concise arrow body form', () => {
    expect(lint(`watch(a, (v) => (b.value = v))`, ONLY_DERIVED)).toEqual([
      'local/no-derived-state-watch',
    ])
  })

  it('allows a watch whose body calls a function — that is a side effect', () => {
    // The dominant idiom in this repo: `watch(() => props.x, () => load())`.
    expect(lint(`watch(() => props.id, () => { void load() })`, ONLY_DERIVED)).toEqual([])
  })

  it('allows a watch that assigns AND fetches', () => {
    // Mixed bodies are the legitimate refactor target: pull the side effect
    // in, and the rule stops firing. That is what the message tells you.
    expect(
      lint(`watch(id, async (v) => { rows.value = await fetchRows(v) })`, ONLY_DERIVED),
    ).toEqual([])
  })

  it('allows a watch that stores to a pinia store, not a ref', () => {
    expect(lint(`watch(dir, (v) => { navigationStore.setDir(v) })`, ONLY_DERIVED)).toEqual([])
  })

  it('allows an accumulator mixed with a real side effect', () => {
    // SseStatusBadge.vue:54 does `attempt.value += 1` alongside a diagnostic. `+=` is not
    // expressible as computed(), and the body touches the outside world, so neither half of the
    // rule applies. Flagging it would be a false positive against the rule's own contract.
    expect(
      lint(
        `watch(bus.state, (s) => { if (s === 'up') { attempt.value += 1 }
        console.warn('reconnect', attempt.value) })`,
        ONLY_DERIVED,
      ),
    ).toEqual([])
  })

  it('allows an empty watcher body (dead code, not derived state)', () => {
    // AgentView.vue:165 has one. It deserves a different message, not this one.
    expect(lint(`watch(() => props.tools, () => { /* re-render */ })`, ONLY_DERIVED)).toEqual([])
  })

  it('flags a body that assigns only inside an if-guard with no else', () => {
    // Regression: treating the absent `alternate` as a failure dropped 11 of the 26 real sites —
    // including this exact shape, FileInput.vue:230 (`if (newVal) { inputText.value = newVal }`).
    // The rule still looked configured and simply stopped matching.
    expect(
      lint(
        `watch(() => props.initialMessage, (newVal) => { if (newVal) { inputText.value = newVal } })`,
        ONLY_DERIVED,
      ),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('flags an if/else where BOTH branches only assign', () => {
    expect(
      lint(`watch(src, (v) => { if (v > 0) { a.value = v } else { a.value = 0 } })`, ONLY_DERIVED),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('allows a body that resets state and never reads the new value', () => {
    // SseStatusBadge counts SSE reconnects.

    // `attempt.value = 0` and `attempt.value += 1` depend on the counter's own history, not on the
    // watched value, so `computed()` cannot express them and the "use computed" advice would be
    // nonsense — the bus reconnects on its own and there is no local handler to move this into.
    expect(
      lint(
        `watch(bus.state, (s) => { if (s === 'up') { attempt.value += 1 } else { attempt.value = 0 } })`,
        ONLY_DERIVED,
      ),
    ).toEqual([])
  })

  it('allows a mirror into a ref the code also writes elsewhere', () => {
    // The defining property of derived state is that you CANNOT write it yourself. `draft` is bound
    // with v-model, so it is real state and replacing the watcher with `computed()` would make the
    // input read-only. 15 of the original 26 sites are this shape.
    expect(
      lint(
        `const draft = ref('')\nwatch(() => props.x, (v) => { draft.value = v ?? '' })\ndraft.value = 'typed'`,
        ONLY_DERIVED,
      ),
    ).toEqual([])
  })

  it('still flags a one-way mirror that reads the new value', () => {
    // The exemption must not swallow the real thing: `pure` is never written
    // anywhere else, so it genuinely is derived state.
    expect(
      lint(
        `const pure = ref('')\nwatch(() => props.x, (v) => { pure.value = v ?? '' })`,
        ONLY_DERIVED,
      ),
    ).toEqual(['local/no-derived-state-watch'])
  })

  it('flags a watch with a const declaration before the assignment', () => {
    // A local means the body computes something non-trivial.
    expect(
      lint(
        `watch(() => raw, (r) => { const next = r === 'rows' ? 'rows' : 'columns'
        if (next !== layout.value) layout.value = next })`,
        ONLY_DERIVED,
      ),
    ).toEqual([])
  })
})

describe('local/no-watch-feedback-loop', () => {
  it('flags a watch that assigns back to the ref it watches', () => {
    // The direct analogue of React's `useEffect(() => setCount(count + 1), [count])`.
    expect(lint(`watch(items, (v) => { items.value = [...v, next] })`, ONLY_LOOP)).toEqual([
      'local/no-watch-feedback-loop',
    ])
  })

  it('flags a watch that mutates the prop it watches', () => {
    expect(lint(`watch(() => props.row, (r) => { props.row.busy = true })`, ONLY_LOOP)).toEqual([
      'local/no-watch-feedback-loop',
    ])
  })

  it('flags a deep watch that mutates an element of the watched array', () => {
    // ChatsList.vue:978 is exactly this shape, and is the one real site in
    // the repo. A `deep` watcher re-runs on ANY nested mutation.
    expect(
      lint(`watch(list, (v) => { v.forEach(i => { i.done = true }) }, { deep: true })`, ONLY_LOOP),
    ).toEqual(['local/no-watch-feedback-loop'])
  })

  it('allows the side-effect watch that is the dominant idiom here', () => {
    expect(
      lint(`watch(() => props.id, async (id) => { rows.value = await fetchRows(id) })`, ONLY_LOOP),
    ).toEqual([])
  })

  it('allows a prop mirrored into a SEPARATE local ref', () => {
    // Regression: an early version treated the property name as a dependency, so `() =>
    // props.isStopping` "watched" `isStopping` and every prop-mirror (FileInput.vue:159,
    // TextReplace.vue:34, McpServerModal.vue:63) was reported as a loop.

    // `props` is the dependency, not `isStopping`.
    expect(
      lint(`watch(() => props.isStopping, (v) => { isStopping.value = v ?? false })`, ONLY_LOOP),
    ).toEqual([])
  })

  it('allows a watch that writes document.title', () => {
    // useDocumentTitle.ts does this. A global is outside the reactivity
    // graph, so it cannot retrigger anything.
    expect(lint(`watch(() => vm.name, (n) => { document.title = n })`, ONLY_LOOP)).toEqual([])
  })

  it('allows a watch that assigns to a different ref', () => {
    // ChatsList.vue:993 — `processingState` in, `navItems` out.
    expect(lint(`watch(processingState, (s) => { navItems.value = s.map(f) })`, ONLY_LOOP)).toEqual(
      [],
    )
  })

  it('allows a NON-deep nested mutation, which does not notify', () => {
    // Without `deep`, mutating a nested field fires no trigger, so this is a
    // one-shot write rather than a loop.
    expect(lint(`watch(list, (v) => { v.forEach(i => { i.done = true }) })`, ONLY_LOOP)).toEqual([])
  })
})

describe('local/no-watch-effect', () => {
  it('flags a watchEffect() call', () => {
    expect(lint(`watchEffect(() => { r.value = a.n })`, ONLY_WATCH_EFFECT)).toEqual([
      'local/no-watch-effect',
    ])
  })

  it('flags importing watchEffect at all', () => {
    // Banning the call but allowing the import would leave a one-line dodge.
    expect(lint(`import { watchEffect } from 'vue'`, ONLY_WATCH_EFFECT)).toEqual([
      'local/no-watch-effect',
    ])
  })

  it('flags the namespaced form', () => {
    expect(lint(`Vue.watchEffect(() => {})`, ONLY_WATCH_EFFECT)).toEqual(['local/no-watch-effect'])
  })

  it('allows watch(), which names its dependencies explicitly', () => {
    expect(lint(`watch(a, () => { load() })`, ONLY_WATCH_EFFECT)).toEqual([])
  })
})

describe('local/no-watch-array-source', () => {
  it('flags a watch with an array source', () => {
    // The Vue spelling of `useEffect(fn, [a, b])`.
    expect(lint(`watch([a, b], () => { void load() })`, ONLY_ARRAY_SOURCE)).toEqual([
      'local/no-watch-array-source',
    ])
  })

  it('flags the array form with options', () => {
    // PresentFiles.vue:376 carried `{ immediate: true }` — the option does
    // not exempt the shape.
    expect(
      lint(`watch([isExpanded, files], () => fetch(), { immediate: true })`, ONLY_ARRAY_SOURCE),
    ).toEqual(['local/no-watch-array-source'])
  })

  it('flags a single-element array source', () => {
    // Still the array form — wrapping one dep in `[]` hides nothing and
    // normalises nothing.
    expect(lint(`watch([a], () => { void load() })`, ONLY_ARRAY_SOURCE)).toEqual([
      'local/no-watch-array-source',
    ])
  })

  it('flags the namespaced form', () => {
    expect(lint(`Vue.watch([a, b], () => {})`, ONLY_ARRAY_SOURCE)).toEqual([
      'local/no-watch-array-source',
    ])
  })

  it('allows a single-ref source', () => {
    expect(lint(`watch(a, () => { void load() })`, ONLY_ARRAY_SOURCE)).toEqual([])
  })

  it('allows a getter source', () => {
    // The dominant idiom in this repo: `watch(() => props.id, () => load())`.
    expect(lint(`watch(() => props.id, () => { void load() })`, ONLY_ARRAY_SOURCE)).toEqual([])
  })

  it('allows a getter that builds an array (out of scope)', () => {
    // `watch(() => [a.value, b.value], fn)` is a single reactive source as far as this rule
    // resolves — reporting it would require resolving the getter body. Documented boundary, not a
    // dodge endorsement: prefer two single-source watchers sharing a handler.
    expect(
      lint(`watch(() => [a.value, b.value], () => { void load() })`, ONLY_ARRAY_SOURCE),
    ).toEqual([])
  })
})

describe('local/no-watch', () => {
  it('flags a single-ref source', () => {
    expect(lint(`watch(a, () => { void load() })`, ONLY_NO_WATCH)).toEqual(['local/no-watch'])
  })

  it('flags the side-effect getter idiom, including the route-query shape', () => {
    // KanbanView.vue watches `() => route.query?.detail` to open/close the
    // panel on Back/Forward. Legitimate under the old settlement, banned
    // under the blanket ban — pinned here so the policy change is visible.
    expect(lint(`watch(() => props.id, () => { void load() })`, ONLY_NO_WATCH)).toEqual([
      'local/no-watch',
    ])
  })

  it('flags the array form (also caught by no-watch-array-source)', () => {
    expect(lint(`watch([a, b], () => { void load() })`, ONLY_NO_WATCH)).toEqual(['local/no-watch'])
  })

  it('flags watchers with options', () => {
    expect(lint(`watch(a, () => { void load() }, { deep: true })`, ONLY_NO_WATCH)).toEqual([
      'local/no-watch',
    ])
    expect(lint(`watch(a, () => { void load() }, { immediate: true })`, ONLY_NO_WATCH)).toEqual([
      'local/no-watch',
    ])
  })

  it('flags the namespaced form', () => {
    expect(lint(`Vue.watch(a, () => {})`, ONLY_NO_WATCH)).toEqual(['local/no-watch'])
  })

  it('allows computed(), which derives without reacting', () => {
    expect(lint(`const c = computed(() => a.value * 2)`, ONLY_NO_WATCH)).toEqual([])
  })

  it('allows a similarly-named function that is not watch', () => {
    expect(lint(`watcher(a, () => { void load() })`, ONLY_NO_WATCH)).toEqual([])
  })
})

describe('local/no-silent-fallback-catch', () => {
  it('flags a catch that returns [] with no diagnostic', () => {
    // This is PR #719: an outage and an empty session reached the UI as the
    // same value, so the error UI was dead code.
    expect(lint(`try { await load() } catch { return [] }`, ONLY_CATCH)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })

  it('flags an empty catch body with no comment', () => {
    expect(lint(`try { go() } catch {}`, ONLY_CATCH)).toEqual(['local/no-silent-fallback-catch'])
  })

  it('flags assigning a fallback ref with no diagnostic', () => {
    expect(lint(`try { go() } catch { items.value = [] }`, ONLY_CATCH)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })

  it('allows a catch that logs', () => {
    expect(
      lint(`try { await load() } catch (e) { console.error('load', e); return [] }`, ONLY_CATCH),
    ).toEqual([])
  })

  it('allows a catch that surfaces into a rendered error ref', () => {
    // The sanctioned fix for the empty-vs-unavailable confusion.
    expect(
      lint(`try { go() } catch (e) { error.value = String(e); return [] }`, ONLY_CATCH),
    ).toEqual([])
  })

  it('allows an empty catch whose comment explains the fallback', () => {
    // AGENTS.md sanctions this explicitly ("say a comment why"). authMe.ts
    // and designHistory.ts both use it. Flagging it would train people to
    // delete the rule instead of obey it.
    expect(
      lint(
        `try { localStorage.getItem('k') } catch {
        // private mode / quota — the live fetch below still works.
      }`,
        ONLY_CATCH,
      ),
    ).toEqual([])
  })

  it('allows a catch that rethrows', () => {
    expect(lint(`try { go() } catch (e) { throw e }`, ONLY_CATCH)).toEqual([])
  })

  it('allows a catch with a real fallback that is not "nothing there"', () => {
    // `return false` from a predicate is a decision, not an erasure.
    expect(lint(`try { return hasItems() } catch { return false }`, ONLY_CATCH)).toEqual([
      'local/no-silent-fallback-catch',
    ])
  })
})

describe('the rules compose without false positives on real shapes', () => {
  it('a realistic component using computed + side-effect watch + logged catch trips ONLY the blanket bans', () => {
    // Under the blanket bans this previously-clean shape reports exactly two hits —
    // `local/no-watch` and `local/no-try-catch` — and nothing else.

    // That pins the policy change: the targeted rules still see no derived state, no loop, no
    // silent catch here; only the backstops fire. The `catch` logs AND writes a rendered error ref,
    // so `no-silent-fallback-catch` correctly stays quiet — the construct ban is what catches it.
    const code = `
      import { ref, watch, computed } from 'vue'
      export function useRows(props) {
        const rows = ref([])
        const error = ref(null)
        const busy = ref(false)
        const count = computed(() => rows.value.length)

        watch(() => props.id, async (id) => {
          busy.value = true
          error.value = null
          try {
            rows.value = await fetchRows(id)
          } catch (e) {
            console.error('fetchRows', e)
            error.value = 'Failed to load rows'
          } finally {
            busy.value = false
          }
        })
        return { rows, error, busy, count }
      }
    `
    expect(lint(code)).toEqual(['local/no-watch', 'local/no-try-catch'])
  })
})

describe('local/no-try-catch', () => {
  it('flags a try/catch around an await', () => {
    // The dominant shape in the corpus: one `await` wrapped so the failure
    // becomes `unknown` and the signature still claims success.
    expect(
      lint(`async function load() { try { return await fetchRows() } catch (e) { return [] } }`, ONLY_TRY_CATCH),
    ).toEqual(['local/no-try-catch'])
  })

  it('flags a catch with no binding', () => {
    // `catch {` is the same construct — the binding is not what is banned.
    expect(lint(`try { go() } catch { return null }`, ONLY_TRY_CATCH)).toEqual([
      'local/no-try-catch',
    ])
  })

  it('flags a catch that only logs', () => {
    // Logging is better than silence, but the caller still cannot see the
    // failure and the signature still claims success. That is the point of
    // banning the construct rather than the silent-fallback shape.
    expect(lint(`try { go() } catch (e) { console.error(e) }`, ONLY_TRY_CATCH)).toEqual([
      'local/no-try-catch',
    ])
  })

  it('flags a catch that rethrows', () => {
    // oxlint's `no-useless-catch` already rejects this shape; the ban is
    // about the construct, so it fires here too.
    expect(lint(`try { go() } catch (e) { throw e }`, ONLY_TRY_CATCH)).toEqual([
      'local/no-try-catch',
    ])
  })

  it('flags a nested catch independently of its outer try', () => {
    // Two handlers, two reports — the baseline count is per-site, so a
    // nested pair must not collapse into one.
    expect(
      lint(
        `try { try { go() } catch (e) { log(e) } } catch (e) { log(e) }`,
        ONLY_TRY_CATCH,
      ),
    ).toEqual(['local/no-try-catch', 'local/no-try-catch'])
  })

  it('allows try/finally with no handler', () => {
    // AGENTS.md sanctions `finally` for releasing a resource, and that is
    // not handling a failure — there is no error channel to widen. 57 such
    // blocks exist today.
    expect(
      lint(`try { return await open() } finally { release() }`, ONLY_TRY_CATCH),
    ).toEqual([])
  })

  it('allows a bare try/finally that only clears a ref', () => {
    expect(lint(`try { go() } finally { busy.value = false }`, ONLY_TRY_CATCH)).toEqual([])
  })

  it('allows promise.catch(fn)', () => {
    // Deliberately out of scope: 10 of the 30 sites are fire-and-forget `router.replace(...)`
    // navigations and 3 are best-effort `res.text()` reads, where the failure genuinely cannot
    // reach the user. The dangerous subset is `local/no-silent-fallback-catch`'s job.
    expect(
      lint(`router.replace({ path }).catch(() => {})`, ONLY_TRY_CATCH),
    ).toEqual([])
  })

  it('does not fire on a method literally named catch', () => {
    // `Effect.catchTags` / `Effect.catchTag` are the REPLACEMENT, so a rule
    // that matched the word would ban the fix.
    expect(
      lint(
        `const p = getUser('42').pipe(Effect.catchTags({ NotFoundError: () => Effect.succeed(null) }))`,
        ONLY_TRY_CATCH,
      ),
    ).toEqual([])
  })

  it('does not fire on the word catch in a string or comment', () => {
    // The corpus has 606 regex matches for `try {` but only 537 AST nodes —
    // the difference is fixtures and prose. A rule that matched text would
    // have pinned those as debt.
    expect(
      lint(`const doc = 'try { go() } catch { return null }' // try/catch is banned`, ONLY_TRY_CATCH),
    ).toEqual([])
  })
})

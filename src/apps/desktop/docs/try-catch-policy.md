# try/catch policy — the failure goes in the type

`local/no-try-catch` bans every `try { … } catch { … }`. Pre-existing sites are
pinned as baseline debt in `eslint-suppressions.json` (537 sites across 132
files). The baseline only shrinks: regenerate with
`pnpm run lint:banned-baseline` **after fixing debt, never to silence a
violation**.

AGENTS.md has said "no try/catch; use Effect-TS" since PR #719. Writing it down
did not make it hold — 521 production `catch` blocks survived across 121 files.
The rule is what makes it hold.

## Why the construct, not just the silent-fallback shape

`local/no-silent-fallback-catch` stays and keeps catching the worst subset: a
`catch` that assigns an empty-looking value with no diagnostic. But the
construct itself is the problem, because a `catch` binding is `unknown`:

- the handler cannot say **what** failed without narrowing it back by hand, so
  the narrowing is usually skipped and the log says `[object Object]`;
- the caller's signature still claims success, so every caller downstream
  inherits a failure it cannot see;
- `Effect.catchTags` / `Effect.retry` / `Effect.timeout` — the things you
  actually want at a failure site — have nothing to attach to.

PR #719 is the canonical cost: `getChatHistory` returned `messages: []` on
transport failure **and** on a real empty session, so `error` stayed `null` and
the UI rendered "How can I help you?" for a session full of messages. The
`chat-load-error` block and its Retry button were dead code.

## 1. The default: `Effect.tryPromise` / `Effect.try`

Put the failure in the type. `src/sync/` is the reference implementation.

```ts
// ❌ banned: `e` is `unknown`, and the signature still says `User | null`
async function getUser(id: string): Promise<User | null> {
  try {
    const res = await fetch(`/api/users/${id}`)
    if (!res.ok) throw new Error('Not found')
    return (await res.json()) as User
  } catch (e) {
    console.error(e)
    return null
  }
}

// ✅ the failure is part of the return type
class FetchError extends Data.TaggedError('FetchError')<{ cause: unknown }> {}
class NotFoundError extends Data.TaggedError('NotFoundError')<{ id: string }> {}
class ParseError extends Data.TaggedError('ParseError')<{ cause: unknown }> {}

const getUser = (id: string) =>
  Effect.gen(function* () {
    const res = yield* Effect.tryPromise({
      try: () => fetch(`/api/users/${id}`),
      catch: (cause) => new FetchError({ cause }),
    })
    if (!res.ok) return yield* Effect.fail(new NotFoundError({ id }))
    return yield* Effect.tryPromise({
      try: () => res.json() as Promise<User>,
      catch: (cause) => new ParseError({ cause }),
    })
  })
// Effect<User, FetchError | NotFoundError | ParseError>
```

Sync code that can throw uses `Effect.try` with the same shape. Real examples
in this repo: `src/sync/SessionEngineDb.ts:99`, `src/sync/ChatEngineDb.ts:133`,
`src/sync/IndexedDbStore.ts:116`.

## 2. Handling it — `catchTags`, not `catch`

```ts
const program = getUser('42').pipe(
  Effect.catchTags({
    NotFoundError: () => Effect.succeed(null),
    FetchError: (e) => Effect.logError('Network issue').pipe(Effect.as(null)),
  }),
  Effect.retry({ times: 3 }),
  Effect.timeout('5 seconds'),
)
Effect.runPromise(program).then(console.log)
```

`Effect.retry` and `Effect.timeout` are the reason this is not a style swap:
they are the two things a hand-rolled `catch` block almost never has.

## 3. Running it from a Vue `<script setup>`

Do not call `Effect.runPromise` at a call site. Reuse the seam in
`src/sync/runtime.ts` — it runs the Effect, logs the squashed cause in dev, and
degrades to a value **the caller named**:

| Helper | Degrades to | Use when |
|---|---|---|
| `runSyncEffect(effect, op)` | `null` | "nothing there" and "could not check" lead to the same action |
| `runSyncEffectOr(effect, fallback, op)` | your `fallback` | the empty answer is not `null` (e.g. `[]` for rows) |
| `runSyncVoid(effect, op)` | nothing | best-effort side effect, e.g. `putLocal` |
| `runSyncResult(effect, op)` | `{ ok: false, reason }` | the UI must render the difference — an `error` ref is shown |

`runSyncResult` exists because `runSyncEffect`'s `null` is exactly the PR #719
bug when the UI has to distinguish them: a documents sidebar that shows "No
documents yet" because the backend was down. If you are about to write
`catch { error.value = '…' }`, this is the variant you want.

## 4. What is still legal

- **`try { … } finally { … }` with no handler.** AGENTS.md sanctions `finally`
  for releasing a resource, and that is not handling a failure — there is no
  error channel to widen. 57 such blocks exist today and the rule does not
  fire on them.
- **`promise.catch(fn)`.** Deliberately out of scope. Ten of its 30 sites are
  fire-and-forget `router.replace(...)` navigations and three are best-effort
  `res.text()` reads — cases where the failure genuinely cannot reach the user,
  which AGENTS.md's "genuinely exceptional" clause covers. Banning it would
  need a promise-vs-Effect discriminator the rule cannot compute without type
  information, and a rule that guesses is a rule that gets deleted. The
  dangerous subset — the `.catch()` that returns an empty-looking value with no
  diagnostic — is already caught by `local/no-silent-fallback-catch`.

## Exemption process

1. Try §1–§3 first. Most sites are a `try` around one `await`, which is a
   one-line `Effect.tryPromise`.
2. If none of them can express it, bring the case to review with the site, the
   attempted spelling, and why it fails. An exemption is a
   `// eslint-disable-next-line local/no-try-catch -- <reason>` with a review
   link, not a helper that hides the `catch`.
3. Never regenerate the baseline to silence a new violation. The baseline is
   debt, and adding to it is a decision that belongs in a PR description.

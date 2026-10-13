/**
 * `try { … } catch { … }` — banned outright in the desktop app.
 *
 * AGENTS.md has said "no try/catch; use Effect-TS" since PR #719, and writing
 * it down did not make it hold: 521 production `catch` blocks survived across
 * 121 files. The rule is now mechanical so the policy is enforced rather than
 * aspirational.
 *
 * WHY the construct itself and not just the silent-fallback shape
 * (`local/no-silent-fallback-catch`, which stays): a `catch` binding is
 * `unknown`, so the handler cannot say what failed without narrowing it back
 * by hand, and the caller's signature still claims success. PR #719 is the
 * canonical cost — `getChatHistory` returned `messages: []` on transport
 * failure AND on a real empty session, so `error` stayed null and the UI
 * rendered "How can I help you?" for a session full of messages.
 *
 * WHAT IS STILL LEGAL, deliberately:
 *
 *   - `try { … } finally { … }` with NO handler. AGENTS.md sanctions `finally`
 *     for releasing a resource, and that is not handling a failure — there is
 *     no error channel to widen. 57 such blocks exist today.
 *   - `// eslint-disable-next-line local/no-try-catch -- <reason>` with a
 *     review link, per the exemption process in `docs/try-catch-policy.md`.
 *
 * WHAT IS OUT OF SCOPE, and why it is a decision rather than an oversight:
 * `promise.catch(fn)` is the same swallowed-failure class, but it is NOT
 * banned here. Ten of its 30 sites are fire-and-forget `router.replace(...)`
 * navigations and three are best-effort `res.text()` reads — cases where the
 * failure genuinely cannot reach the user, which AGENTS.md's "genuinely
 * exceptional" clause covers. Banning it would also need a promise-vs-Effect
 * discriminator this rule cannot compute without type information, and a rule
 * that guesses is a rule that gets deleted. The dangerous subset of `.catch()`
 * — the one that returns an empty-looking value with no diagnostic — is
 * already caught by `local/no-silent-fallback-catch`.
 */
import type { Rule } from 'eslint'

export const noTryCatch: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow try/catch in the desktop app — express the failure in the type with Effect-TS instead.',
    },
    schema: [],
    messages: {
      tryCatch:
        'This catch turns a typed failure into an `unknown` binding, so the caller cannot tell what went wrong and the signature still claims success. Put the failure in the type instead: `Effect.tryPromise({ try: () => fetch(url), catch: (cause) => new FetchError({ cause }) })` makes `FetchError` part of the return type, and `Effect.catchTags` / `Effect.retry` / `Effect.timeout` replace the handler. `src/sync/` is the reference implementation; `runSyncEffect` / `runSyncEffectOr` / `runSyncVoid` (`sync/runtime.ts`) are the Vue `<script setup>` bridge. A bare `try { … } finally { … }` is still allowed — releasing a resource is not handling a failure. If a case genuinely cannot be an Effect, add `// eslint-disable-next-line local/no-try-catch -- <reason>` and bring it to review.',
    },
  },
  create(context) {
    return {
      CatchClause(node) {
        context.report({ node: node as never, messageId: 'tryCatch' })
      },
    }
  },
}

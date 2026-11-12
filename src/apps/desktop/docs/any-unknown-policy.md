# `any` / `unknown` policy — name the type, or parse the boundary once

`local/no-any-unknown` bans `any` everywhere and `unknown` everywhere a value
leaves or is stored. Pre-existing sites are pinned as baseline debt in
`eslint-suppressions.json` (**1,897 sites across 486 files** at the time of
writing: 927 `any`, 970 `unknown`). The baseline only shrinks: regenerate with
`pnpm run lint:banned-baseline` **after fixing debt, never to silence a
violation**.

## Why a second rule when `@typescript-eslint/no-explicit-any` already exists

It exists, it is `error`, and it does nothing. **875 inline
`// eslint-disable-next-line @typescript-eslint/no-explicit-any` comments**
across `src/` switch it off site by site, so the ban is a convention rather
than a gate. `unknown` is covered by no rule at all.

The local rule reports the keyword from the AST, so a disable written for the
upstream rule id does not silence it, and the per-file ratchet is the only way
to hold the debt that is already here.

## The scope, in one sentence

**`any` is banned everywhere. `unknown` is banned everywhere a value LEAVES or
is STORED — a variable annotation, a return type, a generic argument, a cast, a
type alias, a property — and legal where a value ENTERS, which is a function
parameter.**

That asymmetry is the whole point:

| Position | `unknown` | Why |
|---|---|---|
| function parameter | **legal** | the function promises nothing about its input and must narrow it — the sound direction |
| variable annotation | banned | "I gave up naming the type of my own data" |
| return type | banned | pushes the narrowing onto every caller |
| generic argument (`Array<unknown>`) | banned | the container's element type is unnamed |
| cast (`as unknown`) | banned | a cast that names nothing is a cast that checks nothing |
| type alias / interface member / class property | banned | the type is being defined here; name it |

`any` gets no exemption at all, because it disables checking in **both**
directions — reads and writes — so there is no position where it is the honest
type.

## 1. `any` → name the real type

The dominant shape in the corpus is a test double cast to `any` because the
real type is inconvenient to construct:

```ts
// ❌ banned: the mock is unchecked, so a renamed field fails at runtime
useRouteMock.mockReturnValue({ query: { pageId: 'page_42' }, path: '/app' } as any)

// ✅ a typed factory, written once, reused by every spec in the file
function fakeRoute(overrides: Partial<RouteLocationNormalized>): RouteLocationNormalized {
  return { query: {}, path: '/app', fullPath: '/app', ...overrides } as RouteLocationNormalized
}
useRouteMock.mockReturnValue(fakeRoute({ query: { pageId: 'page_42' } }))
```

The same move for a `fetch` mock — the parameters have real types:

```ts
// ❌ banned
vi.spyOn(globalThis, 'fetch').mockImplementation((_url: any, _init?: any) => new Promise(() => {}))

// ✅ the DOM lib already names them
vi.spyOn(globalThis, 'fetch').mockImplementation(
  (_url: RequestInfo | URL, _init?: RequestInit) => new Promise(() => {}),
)
```

When the cast exists because the **real** type is too narrow, widen the real
type — do not cast around it. `apiFetch('/hung', { timeoutMs: 15000 } as any)`
is a missing `timeoutMs` on the options interface, not a reason for `any`.

## 2. `unknown` outside a parameter → parse once, into a named type

`unknown` is sound at a boundary and useless after it: every read needs a
narrowing step, and the narrowing gets written by hand at each call site
instead of once. The repo already has the better shape — a parser module that
turns a wire payload into a typed value once:

```ts
// src/components/tool_outputs/_shared/parsers/fileTools.ts
export function parseTextReplace(data: unknown): ParsedTextReplace {
  const o = unwrapDataRecord(data)
  return { path: strField(o, 'path'), before: strOrNullField(o, 'before') ?? '', /* … */ }
}
```

Every consumer of `parseTextReplace` gets `ParsedTextReplace` for free. That is
the pattern to copy: **one `unknown` parameter at the edge, a named type
inside.** The `unknown` in that signature is legal — it is a parameter.

What is *not* legal is letting the `unknown` travel:

```ts
// ❌ banned: the payload is stored unnamed, so every reader re-narrows
const payload: unknown = await res.json()

// ✅ parsed at the edge, named from there on
const payload: ParsedTextReplace = parseTextReplace(await res.json())
```

## 3. What is still legal

- **`unknown` as a parameter type**, including destructured, rest, defaulted
  and `this` parameters, and in a `v is T` type predicate (a subset of the
  parameter position). This is the boundary, and it is where `unknown` is the
  correct type.
- **`// eslint-disable-next-line local/no-any-unknown -- <reason>`** with a
  review link, per the exemption process below.

## Exemption process

1. Try §1 and §2 first. Most `any` sites are a test double that wants a typed
   factory; most `unknown` sites are a payload that wants a parser.
2. If neither can express it, bring the case to review with the site, the
   attempted spelling, and why it fails. An exemption is a
   `// eslint-disable-next-line local/no-any-unknown -- <reason>` with a review
   link, not a helper that hides the keyword.
3. Never regenerate the baseline to silence a new violation. The baseline is
   debt, and adding to it is a decision that belongs in a PR description.

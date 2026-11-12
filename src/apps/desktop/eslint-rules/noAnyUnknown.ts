/**
 * `any` and `unknown` — banned as type annotations in the desktop app.
 *
 * `@typescript-eslint/no-explicit-any` already forbids `any`, but it is
 * defeated in practice: 875 inline `eslint-disable` comments across `src/`
 * switch it off site by site, so the ban is a convention rather than a gate.
 * `unknown` is covered by no rule at all. This rule reports both keywords
 * from the AST, so a disable written for the upstream rule does not silence
 * it, and the per-file ratchet in `eslint-suppressions.json` is the only way
 * to hold existing debt.
 *
 * THE SCOPE, in one sentence: `any` is banned everywhere, and `unknown` is
 * banned everywhere a value LEAVES or is STORED — a variable annotation, a
 * return type, a generic argument, a cast, a type alias, a property — but
 * legal where a value ENTERS, which is a function parameter. That asymmetry
 * is the whole point: `unknown` as a parameter is the sound direction (the
 * function promises nothing about its input and must narrow it), while
 * `unknown` as a return type or a variable annotation means "I gave up
 * naming the type of my own data" and pushes the narrowing onto every
 * consumer. `any` disables checking in both directions, so it gets no
 * exemption at all.
 *
 * WHY the parameter carve-out is not a loophole: the repo's sanctioned
 * boundary pattern is `parseX(data: unknown): ParsedX` in
 * `components/tool_outputs/_shared/parsers/`, which turns a wire payload into
 * a named type once. A rule that banned its own recommended fix would be
 * deleted within a week, and deleting it takes the `any` ban with it.
 *
 * WHAT IS STILL LEGAL, deliberately:
 *
 *   - `unknown` as a parameter type, including destructured, rest, defaulted
 *     and `this` parameters, and in a `v is T` type predicate (a subset).
 *   - `// eslint-disable-next-line local/no-any-unknown -- <reason>` with a
 *     review link, per the exemption process in `docs/any-unknown-policy.md`.
 *
 * WHAT IS OUT OF SCOPE: `eslint-rules/` itself. The rules are hand-written AST
 * walkers that read `unknown` off parser nodes by design, and they are not
 * under `src/`, so the `app/banned-code` block never sees them.
 */
import type { Rule } from 'eslint'

type Node = { type: string; parent?: Node | null }

const PATTERN_TYPES = new Set([
  'Identifier',
  'ObjectPattern',
  'ArrayPattern',
  'AssignmentPattern',
  'RestElement',
  'TSParameterProperty',
])

const TYPE_WRAPPERS = new Set([
  'TSArrayType',
  'TSTupleType',
  'TSUnionType',
  'TSIntersectionType',
  'TSParenthesizedType',
  'TSOptionalType',
  'TSRestType',
  'TSTypeOperator',
  'TSIndexedAccessType',
  'TSConditionalType',
])

const FUNCTION_TYPES = new Set([
  'FunctionDeclaration',
  'FunctionExpression',
  'ArrowFunctionExpression',
  'TSEmptyBodyFunctionExpression',
  'TSDeclareFunction',
  'TSMethodSignature',
  'TSFunctionType',
  'TSConstructorType',
])

function asNode(value: unknown): Node | null {
  if (!value || typeof value !== 'object') return null
  return typeof (value as { type?: unknown }).type === 'string' ? (value as Node) : null
}

/** True when the keyword sits in a function parameter's type annotation. */
function isParameterAnnotation(node: Node): boolean {
  let cur: Node = node
  let parent = asNode(cur.parent)
  while (parent && TYPE_WRAPPERS.has(parent.type)) {
    cur = parent
    parent = asNode(cur.parent)
  }
  if (!parent || parent.type !== 'TSTypeAnnotation') return false
  const target = asNode(parent.parent)
  if (!target || !PATTERN_TYPES.has(target.type)) return false
  let owner = asNode(target.parent)
  while (owner && PATTERN_TYPES.has(owner.type)) owner = asNode(owner.parent)
  return owner !== null && FUNCTION_TYPES.has(owner.type)
}

export const noAnyUnknown: Rule.RuleModule = {
  meta: {
    type: 'problem',
    docs: {
      description:
        'Disallow `any` and `unknown` type annotations — name the type, or parse the boundary once.',
    },
    schema: [],
    messages: {
      any: '`any` is banned: it erases the error channel and every property read on it is unchecked. Name the real type, or parse the boundary once in a `helpers/**/parsers/*.ts` module and return a typed value. For a test double, type it with the real interface or `Partial<T>`. See `docs/any-unknown-policy.md`.',
      unknown:
        '`unknown` is banned outside a function parameter: as a return type, a variable annotation, a generic argument or a cast it means the narrowing is pushed onto every consumer. Parse the payload once into a named type instead. A parameter is the one legal position — that is where a value enters and `unknown` is the sound type. See `docs/any-unknown-policy.md`.',
    },
  },
  create(context) {
    return {
      TSAnyKeyword(node: Node) {
        context.report({ node: node as never, messageId: 'any' })
      },
      TSUnknownKeyword(node: Node) {
        if (isParameterAnnotation(node)) return
        context.report({ node: node as never, messageId: 'unknown' })
      },
    }
  },
}

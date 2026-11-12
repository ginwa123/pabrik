/** Regression guard for `local/no-any-unknown`. A lint rule that silently stops matching is worse
 * than no rule — it looks enforced and enforces nothing. */
import { describe, expect, it } from 'vitest'
import { Linter } from 'eslint'
import tsParser from '@typescript-eslint/parser'
import plugin from '../../eslint-rules/index'

const linter = new Linter()

const ONLY_ANY_UNKNOWN = ['local/no-any-unknown']

/** Lint `code` with ONLY `local/no-any-unknown` and return the rule ids that fired. */
function lint(code: string): string[] {
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
      rules: Object.fromEntries(ONLY_ANY_UNKNOWN.map((r) => [r, 'error'])),
    },
    // The filename is REQUIRED: a flat config's `files` array is a matching filter, so without a
    // path to match against the block is silently skipped and every rule reports nothing.
    'probe.ts',
  )
  return messages.map((m) => m.ruleId as string)
}

describe('local/no-any-unknown', () => {
  it('flags any in a variable annotation', () => {
    expect(lint(`const payload: any = read()`)).toEqual(['local/no-any-unknown'])
  })

  it('flags any in a cast', () => {
    // `as any` is the shape the 875 inline disables were written for.
    expect(lint(`const row = raw as any`)).toEqual(['local/no-any-unknown'])
  })

  it('flags any as a generic argument', () => {
    expect(lint(`const rows: Array<any> = []`)).toEqual(['local/no-any-unknown'])
  })

  it('flags any in a return type', () => {
    expect(lint(`function read(): any { return go() }`)).toEqual(['local/no-any-unknown'])
  })

  it('flags any as a parameter, which has no exemption', () => {
    // `any` disables checking in both directions, so no position is honest.
    expect(lint(`function read(v: any) { return v }`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown in a variable annotation', () => {
    expect(lint(`const payload: unknown = read()`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown in a return type', () => {
    // The cop-out position: the caller inherits the narrowing.
    expect(lint(`function read(): unknown { return go() }`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown in a cast', () => {
    expect(lint(`const row = raw as unknown`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown in a type alias', () => {
    expect(lint(`type Payload = unknown`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown in a class property', () => {
    expect(lint(`class Box { value: unknown }`)).toEqual(['local/no-any-unknown'])
  })

  it('flags unknown as a generic argument', () => {
    expect(lint(`const rows: Array<unknown> = []`)).toEqual(['local/no-any-unknown'])
  })

  it('flags both keywords on one line as two sites', () => {
    // The baseline count is per-site, so a pair must not collapse into one.
    expect(lint(`const pair: [any, unknown] = [1, 2]`)).toEqual([
      'local/no-any-unknown',
      'local/no-any-unknown',
    ])
  })

  it('allows unknown as a function parameter', () => {
    // The boundary position: the function promises nothing about its input
    // and must narrow it. This is the repo's `parseX(data: unknown)` shape.
    expect(lint(`function parseRow(data: unknown) { return data }`)).toEqual([])
  })

  it('allows unknown as a destructured, rest and defaulted parameter', () => {
    expect(
      lint(
        `function a({ x }: unknown) { return x }; function b(...rest: unknown[]) { return rest }; function c(v: unknown = 1) { return v }`,
      ),
    ).toEqual([])
  })

  it('allows unknown as an arrow and a method parameter', () => {
    expect(lint(`const f = (v: unknown) => v; class C { m(v: unknown) { return v } }`)).toEqual([])
  })

  it('allows unknown as a type predicate parameter', () => {
    // A subset of the parameter position, and the canonical type-guard shape.
    expect(lint(`function isRow(v: unknown): v is Row { return typeof v === 'object' }`)).toEqual(
      [],
    )
  })

  it('still flags unknown in a variable annotation inside a parameter body', () => {
    // The carve-out is the parameter's own annotation, not the whole function.
    expect(
      lint(`function parseRow(data: unknown) { const copy: unknown = data; return copy }`),
    ).toEqual(['local/no-any-unknown'])
  })

  it('allows a named type, a union and a record', () => {
    // The replacement spellings must not trip the rule, or it bans the fix.
    expect(
      lint(
        `const a: Row = row; const b: string | null = null; const c: Record<string, string> = {}`,
      ),
    ).toEqual([])
  })

  it('does not fire on the words in a string or a comment', () => {
    expect(lint(`const doc = 'any and unknown are banned' // any: no`)).toEqual([])
  })
})

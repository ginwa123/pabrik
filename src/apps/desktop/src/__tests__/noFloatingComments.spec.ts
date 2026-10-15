/**
 * Regression guard for `local/no-floating-comments`. A rule that silently stops
 */
import { describe, expect, it } from 'vitest'
import { Linter } from 'eslint'
import tsParser from '@typescript-eslint/parser'
import vueParser from 'eslint-plugin-vue/../../node_modules/.pnpm/vue-eslint-parser@10.4.0_eslint@10.2.0_jiti@2.6.1_/node_modules/vue-eslint-parser'
import plugin from '../../eslint-rules/index'

const linter = new Linter()

const RULE = 'local/no-floating-comments'

/**
 * Lint `code` with ONLY the floating-comment rule enabled and return the
 */
function lines(code: string, filename = 'probe.ts'): number[] {
  const isVue = filename.endsWith('.vue')
  const messages = linter.verify(
    code,
    {
      files: ['**/*.{ts,vue}'],
      languageOptions: {
        parser: (isVue ? vueParser : tsParser) as never,
        parserOptions: isVue
          ? { parser: tsParser as never, ecmaVersion: 2022, sourceType: 'module' }
          : { ecmaVersion: 2022, sourceType: 'module' },
      },
      plugins: { local: plugin as never },
      rules: { [RULE]: 'error' },
    },
    // The filename is REQUIRED: a flat config's `files` array is a matching
    // filter, so without a path to match against the block is silently
    // skipped and the rule reports nothing — assertions would pass vacuously.
    filename,
  )
  return messages.filter((m) => m.ruleId === RULE).map((m) => m.line as number)
}

describe('local/no-floating-comments', () => {
  it('reports a comment block separated from its code by a blank line', () => {
    // The shape the rule exists for: the comment floats, the code is below.
    expect(lines('// a note about the thing\n\nconst x = 1\n')).toEqual([1])
  })

  it('allows a comment that touches the code it explains', () => {
    expect(lines('// a note about the thing\nconst x = 1\n')).toEqual([])
  })

  it('reports the split-to-cheat shape: three blocks, blank-separated, then code', () => {
    // One nine-line comment cut into three three-line blocks so
    // `local/max-comment-lines` sees three findings instead of one.
    const code = [
      '// Alias the key rather than mirroring it into a local ref. This used to be `const keyRef =',
      '// ref(initialKey)` plus a `{ immediate: true }` watcher copying `storageKey.value` into it.',
      '',
      '// The watcher needed the `immediate` flag precisely because the snapshot could not see the',
      '// current value on its own, and it still could not cover a key that changed between setup',
      '// and the first flush.',
      '',
      '// Aliasing reads the live value every time, so a dynamic key is correct from the first',
      '// access and no watcher is needed at all.',
      'const keyRef = storageKey',
      '',
    ].join('\n')
    expect(lines(code)).toEqual([1, 4, 8])
  })

  it('reports every block in the chain, not just the first', () => {
    // Each block is independently guilty: the reader meets all of them before
    // the code, so all of them are reported.
    expect(lines('// one\n// two\n\n// three\n// four\nconst x = 1\n')).toEqual([1, 4])
  })

  it('allows a comment at the end of a file', () => {
    // Nothing below it to attach to, so there is nothing to cheat.
    expect(lines('const x = 1\n\n// a trailing note\n')).toEqual([])
  })

  it('allows a comment before a blank line that is followed by another blank line', () => {
    // Two blanks in a row is a section break, not a split.
    expect(lines('// a section header\n\n\nconst x = 1\n')).toEqual([])
  })

  it('allows a comment before a closing brace', () => {
    // The code it explains is ABOVE it, inside the block.
    expect(lines('function f() {\n  const x = 1\n\n  // a note\n}\n')).toEqual([])
  })

  it('allows a trailing comment after code', () => {
    // A code byte on the line attaches it by construction.
    expect(lines('const x = 1 // a note\n')).toEqual([])
  })

  it('allows a JSDoc block that touches its declaration', () => {
    expect(lines('/** A doc.\n * Second line.\n */\nexport const x = 1\n')).toEqual([])
  })

  it('reports a JSDoc block separated from its declaration', () => {
    expect(lines('/** A doc.\n * Second line.\n */\n\nexport const x = 1\n')).toEqual([1])
  })

  it('reports two comment runs separated by one blank line inside a block', () => {
    // The same split shape as at top level — nesting does not make it legal.
    // An author's paragraph break inside one logical comment is exactly the
    // shape the rule looks for, because a reader cannot tell it apart from a
    // comment that was cut up to dodge the three-line ceiling.
    const code = [
      'function f() {',
      '  // first paragraph',
      '',
      '  // second paragraph',
      '  const x = 1',
      '}',
      '',
    ].join('\n')
    expect(lines(code)).toEqual([2, 4])
  })

  it('allows a comment followed by two blank lines then code inside a block', () => {
    // Two blanks is a section break, not a split.
    const code = ['function f() {', '  // a note', '', '', '  const x = 1', '}', ''].join('\n')
    expect(lines(code)).toEqual([])
  })

  it('reports a comment above a blank line that precedes a nested declaration', () => {
    const code = ['function f() {', '  // a note about x', '', '  const x = 1', '}', ''].join('\n')
    expect(lines(code)).toEqual([2])
  })

  it('handles a .vue file the same way', () => {
    const code = '<script setup lang="ts">\n// a note\n\nconst x = 1\n</script>\n'
    expect(lines(code, 'probe.vue')).toEqual([2])
  })

  it('does not report a comment that is the last line of a .vue script block', () => {
    const code = '<script setup lang="ts">\nconst x = 1\n\n// a note\n</script>\n'
    expect(lines(code, 'probe.vue')).toEqual([])
  })
})

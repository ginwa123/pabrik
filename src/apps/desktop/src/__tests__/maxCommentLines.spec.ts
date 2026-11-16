/** Regression guard for `local/max-comment-lines`. */
import { describe, expect, it } from 'vitest'
import { Linter } from 'eslint'
import tsParser from '@typescript-eslint/parser'
import vueParser from 'eslint-plugin-vue/../../node_modules/.pnpm/vue-eslint-parser@10.4.0_eslint@10.2.0_jiti@2.6.1_/node_modules/vue-eslint-parser'
import plugin from '../../eslint-rules/index'

const linter = new Linter()

const RULE = 'local/max-comment-lines'

/** Lint `code` with ONLY the comment-length rule enabled, at its shipped ceiling. */
function lines(code: string, filename = 'probe.ts'): number[] {
  return report(code, filename, 'error')
}

/** The same run with an explicit rule config, for the option and message cases. */
function report(code: string, filename: string, rule: unknown): number[] {
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
      rules: { [RULE]: rule as never },
    },
    // The filename is REQUIRED: a flat config's `files` array is a matching filter, so without a path to match against the block is skipped and the rule never runs.
    filename,
  )
  return messages.filter((m) => m.ruleId === RULE).map((m) => m.line as number)
}

describe('local/max-comment-lines', () => {
  it('allows a one-line block', () => {
    expect(lines('// one\nconst x = 1\n')).toEqual([])
  })

  it('reports a two-line block at its first line', () => {
    expect(lines('// one\n// two\nconst x = 1\n')).toEqual([1])
  })

  it('reports a four-line block at its first line', () => {
    expect(lines('// one\n// two\n// three\n// four\nconst x = 1\n')).toEqual([1])
  })

  it('reports every block over the ceiling, not just the first', () => {
    expect(lines('// a\n// b\n\n// c\n// d\n\n// e\n')).toEqual([1, 4])
  })

  it('counts a block comment by the lines it spans', () => {
    // A 4-line `/* … */` is one finding at its first line, not one per line.
    expect(lines('const x = 1\n/* one\n two\n three\n four */\n')).toEqual([2])
  })

  it('allows a one-line block comment', () => {
    expect(lines('/* one */\nconst x = 1\n')).toEqual([])
  })

  it('ends a block at a blank line', () => {
    // Two one-line blocks separated by a blank line are both legal.
    expect(lines('// a\n\n// b\nconst x = 1\n')).toEqual([])
  })

  it('ends a block at a line with code on it', () => {
    expect(lines('// a\nconst x = 1\n// b\n')).toEqual([])
  })

  it('does not count a trailing comment towards a block', () => {
    // `const x = 1 // note` carries a code byte, so it is not a comment line.
    expect(
      lines('const a = 1 // one\nconst b = 2 // two\nconst c = 3 // three\nconst d = 4 // four\n'),
    ).toEqual([])
  })

  it('does not treat a comment marker inside a string literal as a comment', () => {
    // ESLint's lexer already knows the difference, so this rule inherits it.
    expect(lines('const url = "https://not-a-comment"\nconst re = /a\\/\\/b/\n')).toEqual([])
  })

  it('joins a line comment onto a preceding block comment', () => {
    // The block ends on line 1, so a `//` on line 2 continues the same block — 2 lines total.
    expect(lines('/* one */\n// two\nconst x = 1\n')).toEqual([1])
  })

  it('keeps a line comment after a blank line separate', () => {
    expect(lines('/* one\n two */\n\n// three\nconst x = 1\n')).toEqual([1])
  })

  it('reports a KDoc block over the ceiling — there is no doc exemption', () => {
    // §4 is explicit: `///` and `//!` count like any other comment.
    expect(lines('/**\n * one\n */\nexport const x = 1\n')).toEqual([1])
  })

  it('allows a one-line KDoc block', () => {
    expect(lines('/** one */\nexport const x = 1\n')).toEqual([])
  })

  it('honours a custom ceiling', () => {
    expect(report('// one\n// two\nconst x = 1\n', 'probe.ts', ['error', { max: 2 }])).toEqual([])
  })

  it('reports the actual span and the ceiling in the message', () => {
    const messages = linter.verify(
      '// one\n// two\n// three\n// four\nconst x = 1\n',
      {
        files: ['**/*.ts'],
        languageOptions: {
          parser: tsParser as never,
          parserOptions: { ecmaVersion: 2022, sourceType: 'module' },
        },
        plugins: { local: plugin as never },
        rules: { [RULE]: 'error' },
      },
      'probe.ts',
    )
    expect(messages).toHaveLength(1)
    expect(messages[0]?.message).toContain('4 lines')
    expect(messages[0]?.message).toContain('ceiling is 1')
  })
})

describe('local/max-comment-lines in .vue files', () => {
  it('reports an over-long block inside <script setup>', () => {
    const code = '<script setup lang="ts">\n// one\n// two\nconst x = 1\n</script>\n'
    expect(lines(code, 'probe.vue')).toEqual([2])
  })

  it('allows a one-line block inside <script setup>', () => {
    const code = '<script setup lang="ts">\n// one\nconst x = 1\n</script>\n'
    expect(lines(code, 'probe.vue')).toEqual([])
  })

  it('reports an over-long block in a SECOND <script> block', () => {
    // DiffCommentBox.vue is the one file with two script blocks.
    const code = [
      '<script lang="ts">',
      'export const x = 1',
      '</script>',
      '',
      '<script setup lang="ts">',
      '// one',
      '// two',
      'export const y = 2',
      '</script>',
      '',
    ].join('\n')
    expect(lines(code, 'probe.vue')).toEqual([6])
  })

  it('does not report HTML comments in <template> — documented gap', () => {
    // Out of scope on purpose: vue-eslint-parser gives the template prose no comment line the rule can count.
    const code =
      '<template>\n  <div>\n    <!-- one\n         two\n         three\n         four -->\n  </div>\n</template>\n'
    expect(lines(code, 'probe.vue')).toEqual([])
  })

  it('does not report CSS comments in <style> — documented gap', () => {
    // `vue-eslint-parser` does not parse the style block, so there is no AST to read.
    const code = '<style>\n/* one\n   two\n   three\n   four */\n.a { color: red }\n</style>\n'
    expect(lines(code, 'probe.vue')).toEqual([])
  })
})

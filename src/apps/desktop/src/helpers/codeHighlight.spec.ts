/** Tests for helpers/codeHighlight.ts. */
import { describe, expect, it } from 'vitest'

import {
  detectLanguage,
  highlightLine,
  highlightLines,
  highlightLinesForFile,
} from './codeHighlight'

describe('detectLanguage', () => {
  it('maps common extensions', () => {
    expect(detectLanguage('foo.ts')).toBe('typescript')
    expect(detectLanguage('foo.tsx')).toBe('typescript')
    expect(detectLanguage('foo.js')).toBe('javascript')
    expect(detectLanguage('foo.vue')).toBe('html')
    expect(detectLanguage('foo.py')).toBe('python')
    expect(detectLanguage('foo.zig')).toBe('zig')
    expect(detectLanguage('foo.rs')).toBe('rust')
    expect(detectLanguage('run.sh')).toBe('shell')
    expect(detectLanguage('a.toml')).toBe('ini')
  })

  it('is case-insensitive and falls back to plaintext', () => {
    expect(detectLanguage('FOO.TS')).toBe('typescript')
    expect(detectLanguage('notes.log')).toBe('plaintext')
    expect(detectLanguage('no-extension')).toBe('plaintext')
    expect(detectLanguage('file.unknownext')).toBe('plaintext')
    expect(detectLanguage('')).toBe('plaintext')
  })
})

describe('highlightLine', () => {
  it('passes plaintext through as a single plain token', () => {
    expect(highlightLine('const x = "hi" // c', 'plaintext')).toEqual([
      { text: 'const x = "hi" // c', type: 'plain' },
    ])
  })

  it('tokenizes typescript keywords, strings, comments, numbers', () => {
    const tokens = highlightLine('const name = "ada"; // greeting', 'typescript')
    expect(tokens).toContainEqual({ text: 'const', type: 'keyword' })
    expect(tokens).toContainEqual({ text: '"ada"', type: 'string' })
    expect(tokens).toContainEqual({ text: '// greeting', type: 'comment' })
    const nums = highlightLine('const n = 42', 'typescript')
    expect(nums).toContainEqual({ text: '42', type: 'number' })
  })

  it('detects function calls and types', () => {
    const tokens = highlightLine('const r = parseTextReplace(data)', 'typescript')
    expect(tokens).toContainEqual({ text: 'parseTextReplace', type: 'function' })
    const types = highlightLine('const w: TextReplaceResult = x', 'typescript')
    expect(types).toContainEqual({ text: 'TextReplaceResult', type: 'type' })
  })

  it('keeps comment markers inside strings as strings (zig)', () => {
    const tokens = highlightLine('const s = "a // b"; // real', 'zig')
    expect(tokens).toContainEqual({ text: '"a // b"', type: 'string' })
    expect(tokens).toContainEqual({ text: '// real', type: 'comment' })
  })

  it('handles python # comments and keywords', () => {
    const tokens = highlightLine('def foo():  # define', 'python')
    expect(tokens).toContainEqual({ text: 'def', type: 'keyword' })
    expect(tokens).toContainEqual({ text: 'foo', type: 'function' })
    expect(tokens).toContainEqual({ text: '# define', type: 'comment' })
  })

  it('handles shell # comments', () => {
    const tokens = highlightLine('echo hi # done', 'shell')
    expect(tokens).toContainEqual({ text: '# done', type: 'comment' })
  })

  it('handles html comments', () => {
    const tokens = highlightLine('<div><!-- note --></div>', 'html')
    expect(tokens).toContainEqual({ text: '<!-- note -->', type: 'comment' })
  })

  it('returns plain for empty lines', () => {
    expect(highlightLine('', 'typescript')).toEqual([{ text: '', type: 'plain' }])
  })

  it('escapes nothing itself — returns raw text (Vue text nodes escape)', () => {
    const tokens = highlightLine('<script>alert(1)</script>', 'typescript')
    expect(tokens.map((t) => t.text).join('')).toBe('<script>alert(1)</script>')
  })
})

describe('highlightLines', () => {
  it('takes a resolved language id, not a path', () => {
    expect(highlightLines(['const x = 1'], 'typescript')).toContainEqual([
      { text: 'const', type: 'keyword' },
      { text: ' ', type: 'plain' },
      { text: 'x', type: 'plain' },
      { text: ' = ', type: 'plain' },
      { text: '1', type: 'number' },
    ])
  })

  it('returns one token list per line, in order', () => {
    const lines = ['def f():', '    return 1', '# done']
    const tokens = highlightLines(lines, 'python')
    expect(tokens).toHaveLength(lines.length)
    for (const [i, line] of lines.entries()) {
      expect(tokens[i]!.map((t) => t.text).join('')).toBe(line)
    }
    expect(tokens[2]).toEqual([{ text: '# done', type: 'comment' }])
  })

  it('is empty for an empty line list', () => {
    expect(highlightLines([], 'typescript')).toEqual([])
  })
})

describe('highlightLinesForFile', () => {
  it('resolves the language from the path, not from the text', () => {
    // Guard against the mix-up this API exists to prevent: a *language id*
    // passed where a path is expected must NOT style the line (it has no
    // extension), while the path does.
    expect(highlightLines(['const x = 1'], 'typescript')).not.toEqual(
      highlightLinesForFile(['const x = 1'], 'typescript'),
    )
    expect(highlightLinesForFile(['const x = 1'], 'a.ts')).toEqual(
      highlightLines(['const x = 1'], 'typescript'),
    )
  })

  it('tokenizes every line, resolving the language from the path once', () => {
    const tokens = highlightLinesForFile(
      ['const x = 1', '// done', 'function run() {}'],
      'src/a.ts',
    )
    expect(tokens).toHaveLength(3)
    expect(tokens[0]).toContainEqual({ text: 'const', type: 'keyword' })
    expect(tokens[0]).toContainEqual({ text: '1', type: 'number' })
    expect(tokens[1]).toEqual([{ text: '// done', type: 'comment' }])
    expect(tokens[2]).toContainEqual({ text: 'function', type: 'keyword' })
  })

  it('keeps the result parallel to the input, one list per line, in order', () => {
    const lines = ['a = 1', 'b = 2', 'c = 3']
    const tokens = highlightLinesForFile(lines, 'x.py')
    expect(tokens).toHaveLength(lines.length)
    for (const [i, line] of lines.entries()) {
      expect(tokens[i]!.map((t) => t.text).join('')).toBe(line)
    }
  })

  it('falls back to plaintext for an unknown, empty or missing path', () => {
    for (const path of ['notes.log', 'no-extension', '', null, undefined]) {
      expect(highlightLinesForFile(['const x = 1'], path)).toEqual([
        [{ text: 'const x = 1', type: 'plain' }],
      ])
    }
  })

  it('is empty for an empty line list (never a phantom row)', () => {
    expect(highlightLinesForFile([], 'a.ts')).toEqual([])
  })
})

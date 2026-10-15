/** Regression test for the sidebar-right open-file doubled path
 * (task fix-open-file). The explorer passes an ABSOLUTE file.path
 * (backend listDirectory joins dir_path + name); the footer must
 * show it as-is and only join relative paths. The logic lives in
 * the shared displayPathFor helper (unit-tested here); this spec
 * additionally asserts the template binds to it. */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

import { displayPathFor } from '../../../composables/useCodeEditorSession'

const codeEditorPath = resolve(__dirname, '..', '..', 'views', 'CodeEditor.vue')

describe('CodeEditor.vue — footer displayPath', () => {
  it('shows absolute filePath as-is (no cwd doubling)', () => {
    expect(displayPathFor('/home/u/work', '/home/u/work/migration/README.md')).toBe(
      '/home/u/work/migration/README.md',
    )
  })

  it('joins relative filePath with cwd', () => {
    expect(displayPathFor('/home/u/work', 'migration/README.md')).toBe(
      '/home/u/work/migration/README.md',
    )
  })

  it('footer binds title and text to displayPath', () => {
    const src = readFileSync(codeEditorPath, 'utf-8')
    expect(src).toMatch(/:title="displayPath"/)
    expect(src).toMatch(/\{\{\s*displayPath\s*\}\}/)
    expect(src).not.toMatch(/cwd \? `\$\{cwd\}\/\$\{filePath\}`/)
  })
})

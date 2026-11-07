import { describe, expect, it } from 'vitest'

import { codeEditorQuery } from '../components/appLayout/codeEditorUrl'

describe('codeEditorQuery', () => {
  const replaced = { session: 'sa', tab: 'tab_1', mode: 'diff' }

  it('carries the cwd the file was resolved against', () => {
    expect(codeEditorQuery(replaced, 'src/a.ts', null, false, '/repo')).toEqual({
      session: 'sa',
      view: 'code-editor',
      file: 'src/a.ts',
      cwd: '/repo',
    })
  })

  it('keeps a deep link cwd when the open resolved none of its own', () => {
    const query = codeEditorQuery({ ...replaced, cwd: '/repo' }, 'src/a.ts', 12, false)
    expect(query.cwd).toBe('/repo')
    expect(query.line).toBe('12')
  })

  it('never inherits the replaced target mode', () => {
    expect(codeEditorQuery(replaced, '/repo/src/a.ts', null, false, '/repo').mode).toBeUndefined()
    expect(codeEditorQuery(replaced, '/repo/src/a.ts', null, true, '/repo').mode).toBe('diff')
  })
})

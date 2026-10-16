// Static-contract regression test: when an active workspace item has `item_type === 'kanban'` or
// `'design'`, the workspace-memories view branch in AppLayout.vue must NOT render
// <WorkspaceItemMemoriesView>, even if the item has a `path` set.
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const APPLAYOUT_PATH = resolve(
  __dirname,
  '..',
  'components',
  'AppLayout.vue',
)

describe('AppLayout — workspace memories view guard', () => {
  const source = readFileSync(APPLAYOUT_PATH, 'utf-8')

  it('does NOT render a redundant outer compact header card', () => {
    // Bug: the outer header duplicated WorkspaceItemMemoriesView's own
    // header. Verify the outer header markup is gone.
    expect(source).not.toContain('Compact header card (always shown when an item is active)')
  })

})
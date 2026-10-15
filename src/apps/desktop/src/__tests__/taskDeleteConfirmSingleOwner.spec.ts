// Static-contract regression test: the task-delete confirmation must have exactly ONE owner. Bug
// (task_1791030815108_1, PR #786): the kanban card mounted its own <ConfirmDialog> whose handler
// only re-emitted `deleteTask` — it never deleted anything.
// That event still reached AppLayout -> Sidebar, whose ConfirmDialog is the real owner, so one
// "Delete task" opened two stacked popups.
// The component-level spec (WorkspaceItemTaskCard.contextMenu.spec.ts) mounts the card in ISOLATION
// and asserts it mounts no dialog. That is necessary but not sufficient: it cannot see a duplicate
// owned by an ANCESTOR, and Sidebar is not in that test tree.
// These assertions close that gap by pinning the ownership in the source itself, so a future "just
// add a confirm here" cannot silently re-create the duplicate. Related skill:
// find-the-terminal-owner-before-adding-a-confirm

import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve, join } from 'node:path'

const SRC = resolve(__dirname, '..')
const COMPONENTS = join(SRC, 'components')

const read = (rel: string) => readFileSync(join(SRC, rel), 'utf8')

// A <ConfirmDialog> MOUNT is an opening tag in a template. Imports and
// prose mentions are deliberately not counted — WorkspaceItemTaskCard
// explains in a comment why it used to have one.
const mountsDialog = (src: string) => /<ConfirmDialog[\s>]/.test(src)

const vueFilesIn = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) return vueFilesIn(full)
    return entry.name.endsWith('.vue') ? [full] : []
  })

describe('task delete — single confirm owner', () => {
  it('no kanban or workspace component mounts a ConfirmDialog', () => {
    const offenders = ['components/kanban', 'components/workspace']
      .flatMap((dir) => vueFilesIn(join(SRC, dir)))
      .filter((path) => mountsDialog(readFileSync(path, 'utf8')))
      .map((path) => path.slice(SRC.length + 1))

    expect(offenders).toEqual([])
  })

  it('the card forwards deleteTask instead of confirming locally', () => {
    const card = read('components/workspace/WorkspaceItemTaskCard.vue')
    expect(card).not.toContain("from '../dialogs/ConfirmDialog.vue'")
    expect(card).not.toMatch(/confirmDeleteOpen/)
    // One emit, straight up the chain, like every other task action.
    expect(card.match(/emit\('deleteTask'/g)).toHaveLength(1)
  })

  it('Sidebar is the sole owner, and is the only caller of the delete', () => {
    const sidebar = read('components/shell/Sidebar.vue')
    expect(mountsDialog(sidebar)).toBe(true)

    // The owner is whoever calls the effect. Exactly one call site in
    // the whole frontend — if this count ever reaches 2, a second gate
    // (and therefore a second popup) exists.
    const callers = vueFilesIn(COMPONENTS).filter((path) =>
      /workspacesStore\.deleteTask|store\.deleteTask\(/.test(readFileSync(path, 'utf8')),
    )
    expect(callers.map((p) => p.slice(COMPONENTS.length + 1))).toEqual([
      join('shell', 'Sidebar.vue'),
    ])
  })
})

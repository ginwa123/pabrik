// Static-contract regression test: the task-delete confirmation must have exactly ONE owner.
import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve, join } from 'node:path'

const SRC = resolve(__dirname, '..')
const COMPONENTS = join(SRC, 'components')

const read = (rel: string) => readFileSync(join(SRC, rel), 'utf8')

// A <ConfirmDialog> MOUNT is an opening tag in a template.
const mountsDialog = (src: string) => /<ConfirmDialog[\s>]/.test(src)

const vueFilesIn = (dir: string): string[] =>
  readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) return vueFilesIn(full)
    return entry.name.endsWith('.vue') ? [full] : []
  })

describe('task delete — single confirm owner', () => {
  it('no component on the task-delete path mounts its own ConfirmDialog', () => {
    // Scoped to components that HANDLE a delete, not to the two directories: a member / secret / PR confirmation is its own gate and has nothing to do with task …
    const offenders = ['components/kanban', 'components/workspace']
      .flatMap((dir) => vueFilesIn(join(SRC, dir)))
      .filter((path) => {
        const src = readFileSync(path, 'utf8')
        return /deleteTask/.test(src) && mountsDialog(src)
      })
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

    // The owner is whoever calls the effect.
    const callers = vueFilesIn(COMPONENTS).filter((path) =>
      /workspacesStore\.deleteTask|store\.deleteTask\(/.test(readFileSync(path, 'utf8')),
    )
    expect(callers.map((p) => p.slice(COMPONENTS.length + 1))).toEqual([
      join('shell', 'Sidebar.vue'),
    ])
  })
})

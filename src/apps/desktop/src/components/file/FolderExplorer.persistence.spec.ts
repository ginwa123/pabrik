import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia, type Pinia } from 'pinia'
import FolderExplorer from './FolderExplorer.vue'
import type { FolderEntry } from '../../api'
import { makeLocalStorageStub } from '../../__tests__/helpers'

const { listFolderMock, getGitChangesMock } = vi.hoisted(() => ({
  listFolderMock: vi.fn(),
  getGitChangesMock: vi.fn(),
}))

vi.mock('../../api', async () => {
  const actual = await vi.importActual<typeof import('../../api')>('../../api')
  return {
    ...actual,
    listFolder: listFolderMock,
    getGitChanges: getGitChangesMock,
  }
})

const dir = (path: string, name: string): FolderEntry => ({
  path,
  name,
  is_directory: true,
  is_symlink: false,
})

const file = (path: string, name: string): FolderEntry => ({
  path,
  name,
  is_directory: false,
  is_symlink: false,
})

const TREE: Record<string, FolderEntry[]> = {
  '/repo': [
    dir('/repo/alpha', 'alpha'),
    dir('/repo/beta', 'beta'),
    dir('/repo/gone', 'gone'),
    file('/repo/readme.md', 'readme.md'),
  ],
  '/repo/alpha': [file('/repo/alpha/alpha-child.ts', 'alpha-child.ts')],
  '/repo/beta': [file('/repo/beta/beta-child.ts', 'beta-child.ts')],
  '/other': [dir('/other/gamma', 'gamma')],
  '/other/gamma': [file('/other/gamma/gamma-child.ts', 'gamma-child.ts')],
}

const NO_GIT = {
  is_git_repo: false,
  branch: '',
  has_changes: false,
  staged_files: [],
  modified_files: [],
  untracked_files: [],
}

function rows(wrapper: ReturnType<typeof mount>) {
  return wrapper.findAll('[data-testid="explorer-row"]')
}

function rowFor(wrapper: ReturnType<typeof mount>, name: string) {
  return rows(wrapper).find((row) => row.text().includes(name))!
}

function rowNames(wrapper: ReturnType<typeof mount>): string[] {
  return rows(wrapper).map((row) => row.text())
}

function isRowOpen(wrapper: ReturnType<typeof mount>, name: string): boolean {
  // `chevron-down` points down already, so expanded is rotate(0deg) and
  // collapsed is rotate(-90deg).
  return rowFor(wrapper, name).html().includes('rotate(0deg)')
}

async function mountExplorer(pinia: Pinia, cwd: string) {
  const wrapper = mount(FolderExplorer, { props: { cwd }, global: { plugins: [pinia] } })
  await flushPromises()
  return wrapper
}

describe('FolderExplorer expansion persistence', () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.clearAllMocks()
    listFolderMock.mockImplementation((path: string) =>
      Promise.resolve({ entries: TREE[path] ?? [] }),
    )
    getGitChangesMock.mockResolvedValue(NO_GIT)
  })

  it('keeps a folder open when the explorer is remounted for the same cwd', async () => {
    const pinia = createPinia()
    const first = await mountExplorer(pinia, '/repo')
    await rowFor(first, 'alpha').trigger('click')
    await flushPromises()
    expect(rowNames(first)).toContain('alpha-child.ts')
    first.unmount()

    const second = await mountExplorer(pinia, '/repo')
    expect(isRowOpen(second, 'alpha')).toBe(true)
    expect(rowNames(second)).toContain('alpha-child.ts')
    second.unmount()
  })

  it('keeps a folder closed when it was collapsed before the remount', async () => {
    const pinia = createPinia()
    const first = await mountExplorer(pinia, '/repo')
    await rowFor(first, 'alpha').trigger('click')
    await flushPromises()
    await rowFor(first, 'alpha').trigger('click')
    await flushPromises()
    expect(rowNames(first)).not.toContain('alpha-child.ts')
    first.unmount()

    const second = await mountExplorer(pinia, '/repo')
    expect(isRowOpen(second, 'alpha')).toBe(false)
    expect(rowNames(second)).not.toContain('alpha-child.ts')
    second.unmount()
  })

  it('gives each cwd its own expansion set across a cwd switch', async () => {
    const pinia = createPinia()
    const wrapper = await mountExplorer(pinia, '/repo')
    await rowFor(wrapper, 'alpha').trigger('click')
    await flushPromises()
    expect(rowNames(wrapper)).toContain('alpha-child.ts')

    await wrapper.setProps({ cwd: '/other' })
    await flushPromises()
    expect(rowNames(wrapper)).not.toContain('alpha-child.ts')
    await rowFor(wrapper, 'gamma').trigger('click')
    await flushPromises()
    expect(rowNames(wrapper)).toContain('gamma-child.ts')

    await wrapper.setProps({ cwd: '/repo' })
    await flushPromises()
    expect(rowNames(wrapper)).toContain('alpha-child.ts')
    expect(rowNames(wrapper)).not.toContain('gamma-child.ts')
    wrapper.unmount()
  })

  it('drops a folder from the saved set when its children cannot be listed', async () => {
    listFolderMock.mockImplementation((path: string) =>
      path === '/repo/gone'
        ? Promise.reject(new Error('unreadable'))
        : Promise.resolve({ entries: TREE[path] ?? [] }),
    )
    const pinia = createPinia()
    const first = await mountExplorer(pinia, '/repo')
    await rowFor(first, 'gone').trigger('click')
    await flushPromises()
    expect(isRowOpen(first, 'gone')).toBe(false)
    first.unmount()

    const second = await mountExplorer(pinia, '/repo')
    expect(isRowOpen(second, 'gone')).toBe(false)
    second.unmount()
  })
})

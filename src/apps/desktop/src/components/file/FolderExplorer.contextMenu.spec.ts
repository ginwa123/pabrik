import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import type { VueWrapper } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import FolderExplorer from './FolderExplorer.vue'

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

const ENTRIES = [
  { path: '/repo/src', name: 'src', is_directory: true, is_symlink: false },
  { path: '/repo/app.ts', name: 'app.ts', is_directory: false, is_symlink: false },
  { path: '/repo/README.md', name: 'README.md', is_directory: false, is_symlink: false },
]

const CLEAN_REPO = {
  is_git_repo: true,
  branch: 'main',
  has_changes: false,
  staged_files: [],
  modified_files: [],
  untracked_files: [],
}

const CURRENT_PAGE = '/app/ws_1/projects/proj_1'

const testRouter = createRouter({
  history: createMemoryHistory(),
  routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
})

async function mountExplorer(): Promise<VueWrapper> {
  const wrapper = mount(FolderExplorer, {
    props: { cwd: '/repo' },
    global: { plugins: [testRouter] },
  })
  await flushPromises()
  return wrapper
}

function rowFor(wrapper: VueWrapper, name: string) {
  const row = wrapper
    .findAll('[data-testid="explorer-row"]')
    .find((candidate) => candidate.text().includes(name))
  if (!row) throw new Error(`no explorer row for ${name}`)
  return row
}

function menuItem(testid: string): HTMLElement | null {
  return document.body.querySelector(`[data-testid="${testid}"]`)
}

function openedUrl(openSpy: { mock: { calls: unknown[][] } }): URL {
  const raw = String(openSpy.mock.calls[0]?.[0] ?? '')
  return new URL(raw, 'http://localhost')
}

describe('FolderExplorer file context menu', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    document.body.innerHTML = ''
    listFolderMock.mockResolvedValue({ entries: ENTRIES })
    getGitChangesMock.mockResolvedValue(CLEAN_REPO)
    await testRouter.push(CURRENT_PAGE)
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('right-clicking a file row offers opening the file in a new tab', async () => {
    const wrapper = await mountExplorer()
    await rowFor(wrapper, 'app.ts').trigger('contextmenu', { clientX: 40, clientY: 80 })
    expect(menuItem('open-file-new-tab-item')?.textContent).toContain('Open file in new tab')
    wrapper.unmount()
  })

  it('choosing open file in new tab loads that file in a new browser tab', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = await mountExplorer()
      await rowFor(wrapper, 'app.ts').trigger('contextmenu', { clientX: 40, clientY: 80 })
      menuItem('open-file-new-tab-item')?.click()
      await flushPromises()

      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openSpy.mock.calls[0]?.[1]).toBe('_blank')
      const url = openedUrl(openSpy)
      expect(url.pathname).toBe(CURRENT_PAGE)
      expect(url.searchParams.get('view')).toBe('code-editor')
      expect(url.searchParams.get('file')).toBe('/repo/app.ts')
      expect(url.searchParams.has('cwd')).toBe(false)

      expect(wrapper.emitted('file-click')).toBeUndefined()
      expect(menuItem('open-new-tab-menu')).toBeNull()
      wrapper.unmount()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('right-clicking a folder row opens no menu', async () => {
    const wrapper = await mountExplorer()
    await rowFor(wrapper, 'src').trigger('contextmenu', { clientX: 40, clientY: 80 })
    expect(menuItem('open-new-tab-menu')).toBeNull()
    wrapper.unmount()
  })

  it('ctrl+click on a file row opens a new tab instead of opening the file inline', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = await mountExplorer()
      await rowFor(wrapper, 'app.ts').trigger('click', { ctrlKey: true })

      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openedUrl(openSpy).searchParams.get('file')).toBe('/repo/app.ts')
      expect(wrapper.emitted('file-click')).toBeUndefined()
      wrapper.unmount()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('middle-click on a file row opens a new tab instead of opening the file inline', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = await mountExplorer()
      await rowFor(wrapper, 'app.ts').trigger('auxclick', { button: 1 })

      expect(openSpy).toHaveBeenCalledTimes(1)
      expect(openedUrl(openSpy).searchParams.get('file')).toBe('/repo/app.ts')
      expect(wrapper.emitted('file-click')).toBeUndefined()
      wrapper.unmount()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('a plain click on a file row still opens the file inline', async () => {
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    try {
      const wrapper = await mountExplorer()
      await rowFor(wrapper, 'README.md').trigger('click')

      expect(wrapper.emitted('file-click')?.[0]?.[0]).toMatchObject({ name: 'README.md' })
      expect(openSpy).not.toHaveBeenCalled()
      wrapper.unmount()
    } finally {
      openSpy.mockRestore()
    }
  })

  it('a plain click on a folder row still expands it and emits folder-click', async () => {
    const wrapper = await mountExplorer()
    listFolderMock.mockResolvedValue({ entries: [] })
    await rowFor(wrapper, 'src').trigger('click')

    expect(wrapper.emitted('folder-click')?.[0]?.[0]).toMatchObject({ name: 'src' })
    expect(wrapper.emitted('file-click')).toBeUndefined()
    wrapper.unmount()
  })
})

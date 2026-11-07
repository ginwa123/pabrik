import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createRouter, createMemoryHistory } from 'vue-router'
import { createPinia } from 'pinia'
import { defineComponent, h, provide } from 'vue'
import ChatRightSidebar from '../chat_right_sidebar/ChatRightSidebar.vue'
import { OPEN_IN_CODE_EDITOR_KEY, type OpenInCodeEditorFn } from '@/composables/useCodeEditor'
import { makeLocalStorageStub } from '../../../__tests__/helpers'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const { getGitChangesMock, listFolderMock } = vi.hoisted(() => ({
  getGitChangesMock: vi.fn(),
  listFolderMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    listFolder: listFolderMock,
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

vi.mock('@xterm/xterm', () => ({
  Terminal: class {
    loadAddon() {}
    open() {}
    write() {}
    onData() {}
    dispose() {}
  },
}))
vi.mock('@xterm/addon-fit', () => ({
  FitAddon: class {
    fit() {}
  },
}))

const makeRouter = (sidebar?: string) => {
  const query: Record<string, string> = {}
  if (sidebar) query.sidebar = sidebar
  return createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/', component: { template: '<div/>' } }],
  })
}

describe('ChatRightSidebar explorer tab', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
    listFolderMock.mockResolvedValue({
      entries: [{ path: 'a.txt', name: 'a.txt', is_directory: false, is_symlink: false }],
    })
  })

  it('defaults to explorer with no saved state', async () => {
    const router = makeRouter()
    router.push({ path: '/', query: {} })
    await router.isReady()
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 300 },
      global: { plugins: [router, createPinia()] },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="chat-right-sidebar-tab-explorer"]').exists()).toBe(true)
    expect(
      wrapper.find('[data-testid="chat-right-sidebar-tab-explorer"]').attributes('aria-selected'),
    ).toBe('true')
    expect(wrapper.find('[data-testid="chat-right-sidebar-explorer"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="folder-explorer"]').exists()).toBe(true)
  })

  it('clicking changes persists ?sidebar=changes and shows the diff panel', async () => {
    const router = makeRouter()
    router.push({ path: '/', query: {} })
    await router.isReady()
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 300 },
      global: { plugins: [router, createPinia()] },
    })
    await flushPromises()
    await wrapper.find('[data-testid="chat-right-sidebar-tab-changes"]').trigger('click')
    await flushPromises()
    expect(localStorage.getItem('pabrik-right-sidebar-panel')).toBe('changes')
    expect(router.currentRoute.value.query.sidebar).toBe('changes')
    expect(wrapper.find('[data-testid="sidebar-diff-panel"]').exists()).toBe(true)
  })

  it('mount with ?sidebar=terminal restores the terminal tab', async () => {
    const router = makeRouter()
    router.push({ path: '/', query: { sidebar: 'terminal' } })
    await router.isReady()
    // jsdom URL must carry the param too (loadPanel reads window.location).
    window.history.replaceState({}, '', '/?sidebar=terminal')
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 300 },
      global: { plugins: [router, createPinia()] },
    })
    await flushPromises()
    expect(
      wrapper.find('[data-testid="chat-right-sidebar-tab-terminal"]').attributes('aria-selected'),
    ).toBe('true')
    window.history.replaceState({}, '', '/')
  })

  it('explorer file-click opens in the CodeEditor with the sidebar cwd', async () => {
    const openInEditor: OpenInCodeEditorFn = vi.fn()
    const router = makeRouter()
    router.push({ path: '/', query: {} })
    await router.isReady()
    // Symbol-keyed injection (OPEN_IN_CODE_EDITOR_KEY) does not travel via
    // mount `global.provide` — wrap in a parent that provide()s it, same
    // pattern as ListDirectory.spec.ts.
    const Host = defineComponent({
      setup() {
        provide(OPEN_IN_CODE_EDITOR_KEY, openInEditor)
        return () => h(ChatRightSidebar, { cwd: '/worktree/chat-1', open: true, width: 300 })
      },
    })
    const wrapper = mount(Host, {
      global: { plugins: [router, createPinia()] },
    })
    await flushPromises()
    // FolderExplorer lists a.txt from the mocked listFolder.
    const fileBtn = wrapper.findAll('button').find((b) => b.text().includes('a.txt'))
    expect(fileBtn?.exists()).toBe(true)
    await fileBtn!.trigger('click')
    expect(openInEditor).toHaveBeenCalledWith({
      filePath: 'a.txt',
      fileName: 'a.txt',
      cwd: '/worktree/chat-1',
    })
  })
})

import { describe, expect, it, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { createPinia } from 'pinia'
import ChatRightSidebar from '../chat_right_sidebar/ChatRightSidebar.vue'
import { clearFolderDiffCache } from '../../../helpers/folderDiffCache'

const { getGitChangesMock } = vi.hoisted(() => ({ getGitChangesMock: vi.fn() }))

// jsdom has no layout/canvas for the real xterm renderer — stub it so the
// always-mounted TerminalTab does not crash the suite (matchMedia).
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

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getGitChanges: getGitChangesMock,
    getGitFolderDiffs: vi.fn(async () => ({ diffs: [] })),
    listFolder: vi.fn().mockResolvedValue({ entries: [] }),
    stageGitFiles: vi.fn(),
    unstageGitFiles: vi.fn(),
  }
})

describe('ChatRightSidebar', () => {
  beforeEach(() => {
    clearFolderDiffCache()
    vi.clearAllMocks()
    getGitChangesMock.mockResolvedValue({
      is_git_repo: true,
      branch: 'main',
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    })
  })

  it('renders nothing when closed', () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: false, width: 300 },
      global: { plugins: [createPinia()] },
    })
    expect(wrapper.find('[data-testid="chat-right-sidebar"]').exists()).toBe(false)
  })

  it('renders panel with width when open', async () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 320 },
      global: { plugins: [createPinia()] },
    })
    await flushPromises()
    const aside = wrapper.get('[data-testid="chat-right-sidebar"]')
    expect(aside.attributes('style')).toContain('320px')
    // Inline flex sibling: squeezes the chat (reactive layout, no overlay).
    expect(aside.classes()).toContain('hidden')
    expect(aside.classes()).toContain('shrink-0')
    expect(aside.classes()).not.toContain('absolute')
    expect(wrapper.find('[data-testid="sidebar-diff-panel"]').exists()).toBe(true)
  })

  it('emits close on ✕ click', async () => {
    const wrapper = mount(ChatRightSidebar, {
      props: { cwd: '/repo', open: true, width: 300 },
      global: { plugins: [createPinia()] },
    })
    await flushPromises()
    await wrapper.get('[data-testid="chat-right-sidebar-close"]').trigger('click')
    expect(wrapper.emitted('update:open')).toEqual([[false]])
  })
})

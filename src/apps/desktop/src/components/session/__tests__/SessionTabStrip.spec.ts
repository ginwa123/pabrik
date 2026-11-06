import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import SessionTabStrip from '../SessionTabStrip.vue'
import { TAB_STRIP_ACTIONS_KEY, type TabStripActions } from '../../../composables/useTabStrip'
import { fetchFolderDiff } from '../../../helpers/folderDiffCache'
import { __resetWindowIdForTests } from '../../../helpers/windowId'
import { useTabsStore } from '../../../stores/tabs'
import { makeLocalStorageStub } from '../../../__tests__/helpers'

// The strip's counts come from the same folder snapshot the right sidebar uses; the spec answers for
// it so the numbers are deterministic.
vi.mock('../../../helpers/folderDiffCache', () => ({ fetchFolderDiff: vi.fn() }))

const mockDiff = fetchFolderDiff as unknown as ReturnType<typeof vi.fn>

/** A unified diff the counter can read: a hunk header, then the added and removed lines. */
const diffWith = (added: number, removed: number) => ({
  path: 'x',
  staged: false,
  diff_content: [
    'diff --git a/x b/x',
    '@@ -1,2 +1,2 @@',
    ...Array.from({ length: added }, () => '+added line'),
    ...Array.from({ length: removed }, () => '-removed line'),
  ].join('\n'),
})

const fileIn = (session: string, path: string, cwd = '/repo') => ({
  view: 'code-editor',
  file: path,
  cwd,
  session,
})

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_strip' }),
    writable: true,
    configurable: true,
  })
}

function actions(): TabStripActions {
  return { activate: vi.fn(), close: vi.fn(), openDiff: vi.fn() }
}

function mountStrip(props: Record<string, unknown>, provided?: TabStripActions) {
  return mount(SessionTabStrip, {
    props: { owner: 'sa', title: 'fix zig test output', ...props },
    global: {
      provide: provided ? { [TAB_STRIP_ACTIONS_KEY as symbol]: provided } : {},
    },
  })
}

/** Two sessions, each with a file, so every assertion can prove the row is the owner's own. The
 * active tab is left on session B's file, which is what happens in the app: you are looking at one
 * session, so the other session's row has no active tab. */
function seedTwoSessions() {
  const tabs = useTabsStore()
  tabs.open({ query: { view: 'chat', session: 'sa' }, title: 'fix zig test output' })
  tabs.open({ query: fileIn('sa', 'src/tabs.ts') })
  tabs.open({ query: { view: 'chat', session: 'sb' }, title: 'durable agent server' })
  tabs.open({ query: fileIn('sb', 'src/tabs.ts') })
  return tabs
}

/** Put the caret on the file tab of `session`, i.e. the row is the one on screen. */
function activateFileOf(session: string) {
  const tabs = useTabsStore()
  const tab = tabs.stripOf(session).find((candidate) => candidate.kind === 'file')
  tabs.activate(tab?.id ?? '')
  return tabs
}

describe('SessionTabStrip', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
    mockDiff.mockReset()
    mockDiff.mockResolvedValue(diffWith(0, 0))
  })

  it('renders its own session row and nothing from another session', () => {
    const tabs = seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa' })
    const labels = wrapper.findAll('[role="tab"]').map((node) => node.text())
    expect(labels).toEqual(['fix zig test output', 'tabs.ts'])
    expect(wrapper.findAll('[role="tab"]')).toHaveLength(tabs.stripOf('sa').length)

    const other = mountStrip({ owner: 'sb' })
    expect(other.findAll('[role="tab"]').map((node) => node.text())).toEqual([
      'durable agent server',
      'tabs.ts',
    ])
    // the same file name in both rows, and never the same node twice
    expect(wrapper.findAll('[role="tab"]').length + other.findAll('[role="tab"]').length).toBe(4)
  })

  it('gives the session its own tab without a close control', () => {
    seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa' })
    const pinned = wrapper.find('.session-tab.is-pinned')
    expect(pinned.exists()).toBe(true)
    expect(pinned.find('[data-testid="session-tab-close-chat"]').exists()).toBe(false)

    const artifact = wrapper.find('[data-testid="session-tab-file"]')
    expect(artifact.find('[data-testid="session-tab-close-file"]').exists()).toBe(true)
  })

  it('shows the active tab only when this row is the one on screen', () => {
    seedTwoSessions()
    // another session is on screen: this row has no active tab, and nothing is highlighted
    const idle = mountStrip({ owner: 'sa' })
    expect(idle.findAll('[aria-selected="true"]')).toHaveLength(0)

    activateFileOf('sa')
    const wrapper = mountStrip({ owner: 'sa' })
    const active = wrapper.findAll('[aria-selected="true"]')
    expect(active).toHaveLength(1)
    expect(active[0]?.text()).toBe('tabs.ts')
  })

  it('asks to activate on click and to close on the close control', async () => {
    const tabs = seedTwoSessions()
    const handler = actions()
    const wrapper = mountStrip({ owner: 'sa' }, handler)

    const pinnedId = tabs.stripOf('sa')[0]?.id ?? ''
    await wrapper.find('.session-tab.is-pinned').trigger('click')
    expect(handler.activate).toHaveBeenCalledWith(pinnedId)

    await wrapper.find('[data-testid="session-tab-close-file"]').trigger('click')
    const fileId = tabs.stripOf('sa').find((tab) => tab.kind === 'file')?.id ?? ''
    expect(handler.close).toHaveBeenCalledWith(fileId)
    // the close control never activates as a side effect
    expect(handler.activate).toHaveBeenCalledTimes(1)
  })

  it('activates and closes through the store when nothing provides the actions', async () => {
    const tabs = seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa' })

    await wrapper.find('.session-tab.is-pinned').trigger('click')
    expect(tabs.activeTabId).toBe(tabs.stripOf('sa')[0]?.id)

    const fileTab = tabs.stripOf('sa').find((tab) => tab.kind === 'file')
    await wrapper.find('[data-testid="session-tab-close-file"]').trigger('click')
    expect(tabs.stripOf('sa').some((tab) => tab.id === fileTab?.id)).toBe(false)
  })

  it('offers the diff of the active file, and not of a diff or of the session', async () => {
    seedTwoSessions()
    const tabs = activateFileOf('sa')
    const handler = actions()
    const wrapper = mountStrip({ owner: 'sa' }, handler)

    // the active tab is the file the row opened last
    expect(wrapper.find('[data-testid="session-strip-open-diff"]').exists()).toBe(true)
    await wrapper.find('[data-testid="session-strip-open-diff"]').trigger('click')
    expect(handler.openDiff).toHaveBeenCalledTimes(1)

    tabs.activate(tabs.stripOf('sa')[0]?.id ?? '')
    await wrapper.vm.$nextTick()
    // the session's own tab is not a file, so there is nothing to diff
    expect(wrapper.find('[data-testid="session-strip-open-diff"]').exists()).toBe(false)

    const diffTab = tabs.openInSession('sa', {
      query: { ...fileIn('sa', 'src/tabs.ts'), mode: 'diff' },
    })
    tabs.activate(diffTab.id)
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="session-strip-open-diff"]').exists()).toBe(false)
  })

  it('hands the sidebar toggle and the close up to its host', async () => {
    seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa' })
    await wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').trigger('click')
    await wrapper.find('[data-testid="chat-app-bar-close"]').trigger('click')
    expect(wrapper.emitted('toggle-sidebar')).toHaveLength(1)
    expect(wrapper.emitted('close')).toHaveLength(1)
  })

  it('drops the sidebar toggle when the host has none to offer', () => {
    seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa', showSidebarToggle: false })
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(false)
  })

  // The width control moved to the composer row: the strip is the title bar now.
  it('does not carry the transcript width control', () => {
    seedTwoSessions()
    const wrapper = mountStrip({ owner: 'sa' })
    expect(wrapper.find('[data-testid="session-strip-width-toggle"]').exists()).toBe(false)
  })

  it("wears the file's own +N \u2212M once the diff arrives", async () => {
    mockDiff.mockResolvedValue(diffWith(3, 1))
    const tabs = seedTwoSessions()
    activateFileOf('sa')

    const wrapper = mountStrip({ owner: 'sa' })
    await flushPromises()

    const counts = wrapper.findAll('[data-testid="session-tab-counts"]')
    expect(counts).toHaveLength(1)
    expect(counts[0]?.text()).toContain('+3')
    expect(counts[0]?.text()).toContain('\u22121')
    // the file is on screen, so nothing is unseen
    expect(wrapper.find('[data-testid="session-tab-unseen"]').exists()).toBe(false)
    // the session's own tab never wears counts
    expect(tabs.stripOf('sa')[0]?.kind).toBe('chat')
  })

  it('stays quiet for a clean file', async () => {
    seedTwoSessions()
    activateFileOf('sa')
    const wrapper = mountStrip({ owner: 'sa' })
    await flushPromises()
    expect(wrapper.find('[data-testid="session-tab-counts"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="session-tab-unseen"]').exists()).toBe(false)
  })

  it('squares a tab whose numbers moved while you were looking elsewhere', async () => {
    // 1. the file is open and looked at: the mount refresh records what it saw
    mockDiff.mockResolvedValue(diffWith(3, 1))
    const tabs = seedTwoSessions()
    activateFileOf('sa')
    const wrapper = mountStrip({ owner: 'sa' })
    await flushPromises()
    expect(wrapper.find('[data-testid="session-tab-unseen"]').exists()).toBe(false)

    // 2. the agent edits it, and the user opens another file: looking at the new tab is the gesture
    //    that refreshes, and it finds the first file changed underneath
    mockDiff.mockResolvedValue(diffWith(9, 4))
    // opened in the background so the click below is the gesture that activates it
    tabs.openInBackground({ query: fileIn('sa', 'src/other.ts') })
    await wrapper.vm.$nextTick()
    const fileTabs = wrapper.findAll('[data-testid="session-tab-file"]')
    expect(fileTabs).toHaveLength(2)
    await fileTabs[1]?.trigger('click')
    await flushPromises()

    const marks = wrapper.findAll('[data-testid="session-tab-unseen"]')
    expect(marks).toHaveLength(1)
    // the square belongs to the tab you are NOT on, and that tab is off screen
    expect(wrapper.findAll('[aria-selected="true"]')).toHaveLength(1)
    expect(wrapper.find('.session-tab.is-active [data-testid="session-tab-unseen"]').exists()).toBe(
      false,
    )
  })
})

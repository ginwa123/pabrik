/** RightSideBarSkillList.vue — the sidebar's skills pane. One list now (a skill is a row scoped to
 * one workspace), fed by `getSkills(workspaceId)`. Three things are pinned here because they are
 * where this pane breaks: 1. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import RightSideBarSkillList from '../RightSideBarSkillList.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillsMock } = vi.hoisted(() => ({ getSkillsMock: vi.fn() }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, getSkills: getSkillsMock }
})

// jsdom 29 dropped localStorage from default globals. The sidebar store
// reads it while the store is created, so the stub has to exist before
// any component touches `useSidebarStore()`.
beforeAll(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })
})

function makeWorkspace(id: string, name: string): Workspace {
  return { id, name, icon: '📁', items: [], expanded: true }
}

/** Populates the store WITHOUT setting `activeWorkspaceId` — the state a
 *  user is in after reaching the sidebar by clicking a project row. */
function seedWorkspacesOnly(ws: Workspace | null): void {
  const store = useWorkspacesStore()
  store.workspaces = ws ? [ws] : []
}

/** The inline `style` of the collapsible container wrapping the rows. */
const listContainerStyle = (wrapper: ReturnType<typeof mount>): string =>
  wrapper.findAll('[data-skill-name]')[0]!.element.parentElement?.getAttribute('style') ?? ''

const SKILLS = {
  skills: [
    { name: 'pdf', description: 'convert PDFs to images' },
    { name: 'skill-creator', description: 'author and evaluate skills' },
  ],
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillsMock.mockReset()
  localStorage.clear()
})

describe('RightSideBarSkillList — one list, scoped to the active workspace', () => {
  it('fetches with the resolved workspace id, not the null raw ref', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue(SKILLS)

    mount(RightSideBarSkillList)
    await flushPromises()

    // `activeWorkspaceId` was never set, so a component bound to the raw
    // ref would have requested nothing at all here.
    expect(useWorkspacesStore().activeWorkspaceId).toBeNull()
    expect(getSkillsMock).toHaveBeenCalledWith('ws_1')
  })

  it('renders one section holding every skill, with no path and no tier', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue(SKILLS)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    const names = wrapper.findAll('[data-skill-name]').map((b) => b.attributes('data-skill-name'))
    expect(names).toEqual(['pdf', 'skill-creator'])
    expect(wrapper.text()).toContain('Skills (2)')
    expect(wrapper.find('[data-testid="skills-list-section-toggle"]').exists()).toBe(true)
    // The two collapsible sections, their icons and the row paths are gone.
    expect(wrapper.text()).not.toContain('Global Skills')
    expect(wrapper.text()).not.toContain('Local Skills')
    // Positive control first: the toggle itself still draws an icon, so
    // the two absences below cannot pass because the selector is dead.
    expect(wrapper.find('[data-icon="brain"]').exists()).toBe(true)
    expect(wrapper.find('[data-icon="globe"]').exists()).toBe(false)
    expect(wrapper.find('[data-icon="folder"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('SKILL.MD')
    expect(wrapper.find('[data-testid="skills-list-count"]').text()).toBe('2 skills')
  })

  it('emits skill-click with the whole row', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue(SKILLS)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()
    await wrapper.findAll('[data-skill-name]')[0]!.trigger('click')

    expect(wrapper.emitted('skill-click')).toEqual([
      [{ name: 'pdf', description: 'convert PDFs to images' }],
    ])
  })

  it('renders an empty list as empty, not as a failure', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue({ skills: [] })

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    expect(wrapper.find('[data-testid="skills-list-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skills-list-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="skills-list-count"]').text()).toBe('0 skills')
  })

  it('renders a failed request as a failure with its reason', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockRejectedValue(new Error('HTTP 500 from /workspaces/ws_1/skills'))

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    expect(wrapper.find('[data-testid="skills-list-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skills-list-error"]').text()).toContain('HTTP 500')
    expect(wrapper.find('[data-testid="skills-list-error"]').text()).toContain('skills.load')
    // The empty state must NOT be reachable from a failure.
    expect(wrapper.find('[data-testid="skills-list-empty"]').exists()).toBe(false)
    expect(wrapper.findAll('[data-skill-name]')).toHaveLength(0)
  })

  it('Retry re-requests and recovers', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockRejectedValueOnce(new Error('network down'))
    getSkillsMock.mockResolvedValueOnce(SKILLS)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()
    expect(wrapper.find('[data-testid="skills-list-error"]').exists()).toBe(true)

    await wrapper.find('[data-testid="skills-list-error"] button').trigger('click')
    await flushPromises()

    expect(getSkillsMock).toHaveBeenCalledTimes(2)
    expect(wrapper.find('[data-testid="skills-list-error"]').exists()).toBe(false)
    expect(wrapper.findAll('[data-skill-name]')).toHaveLength(2)
  })

  it('renders a payload with no skills key as zero rows, not as a crash', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue({})

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    expect(wrapper.find('[data-testid="skills-list-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skills-list-error"]').exists()).toBe(false)
  })

  it('survives a payload whose skills field is not an array', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue({ skills: 'nope' })

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    expect(wrapper.find('[data-testid="skills-list-empty"]').exists()).toBe(true)
  })

  it('says a workspace is needed, and fetches nothing, when none resolves', async () => {
    seedWorkspacesOnly(null)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    expect(getSkillsMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skills-list-no-workspace"]').exists()).toBe(true)
    // Not "No skills available" — there is nothing to have skills in.
    expect(wrapper.find('[data-testid="skills-list-empty"]').exists()).toBe(false)
  })

  it('reloads when the active workspace changes', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue(SKILLS)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()
    expect(getSkillsMock).toHaveBeenCalledTimes(1)

    useWorkspacesStore().workspaces = [
      makeWorkspace('ws_1', 'First'),
      makeWorkspace('ws_2', 'Second'),
    ]
    useWorkspacesStore().setActiveWorkspace('ws_2')
    await flushPromises()

    expect(getSkillsMock).toHaveBeenLastCalledWith('ws_2')
    wrapper.unmount()
  })

  it('renders rows with an empty description', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue({ skills: [{ name: 'bare', description: '' }] })

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()

    const rows = wrapper.findAll('[data-skill-name]')
    expect(rows).toHaveLength(1)
    expect(rows[0]!.text()).toContain('bare')
  })

  it('collapses and expands the single section', async () => {
    seedWorkspacesOnly(makeWorkspace('ws_1', 'First'))
    getSkillsMock.mockResolvedValue(SKILLS)

    const wrapper = mount(RightSideBarSkillList)
    await flushPromises()
    expect(wrapper.find('[data-testid="skills-list-section-toggle"]').text()).toContain(
      'Skills (2)',
    )

    await wrapper.find('[data-testid="skills-list-section-toggle"]').trigger('click')
    // `v-show`, so the rows stay mounted and only the container's inline `display` changes.
    // Asserted on that attribute rather than on `isVisible()`: jsdom caches the computed cascade
    // and keeps reporting `display: none` after the inline style was cleared.
    expect(listContainerStyle(wrapper)).toContain('display: none')

    await wrapper.find('[data-testid="skills-list-section-toggle"]').trigger('click')
    expect(listContainerStyle(wrapper)).not.toContain('display: none')
  })
})

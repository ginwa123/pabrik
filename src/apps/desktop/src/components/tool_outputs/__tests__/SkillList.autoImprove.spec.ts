/** SkillList.vue — the per-row agent lock. The list is the only surface that shows every skill at
 * once, so it is where "which of these may the agent touch?" is answerable. Two things have to
 * hold: 1. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import SkillList from '../SkillList.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillsMock, updateSkillMock } = vi.hoisted(() => ({
  getSkillsMock: vi.fn(),
  updateSkillMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, getSkills: getSkillsMock, updateSkill: updateSkillMock }
})

const WS_ID = 'ws_1'

function seedWorkspace(): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id: WS_ID, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillsMock.mockReset()
  updateSkillMock.mockReset()
  getSkillsMock.mockResolvedValue({
    skills: [
      { name: 'alpha', description: 'first', is_can_auto_improve: true },
      { name: 'beta', description: 'second', is_can_auto_improve: false },
    ],
  })
})

const toggles = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="skill-auto-improve-toggle"]')

const toggleFor = (wrapper: ReturnType<typeof mount>, skillName: string) =>
  wrapper.find(`[data-skill-name="${skillName}"] [data-testid="skill-auto-improve-toggle"]`)

const checkedFor = (wrapper: ReturnType<typeof mount>, skillName: string) =>
  (toggleFor(wrapper, skillName).element as HTMLInputElement).checked

describe('SkillList — the auto-improve lock', () => {
  it('renders one checkbox per row, each showing its own lock state', async () => {
    seedWorkspace()
    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()

    expect(toggles(wrapper)).toHaveLength(2)
    expect(checkedFor(wrapper, 'alpha')).toBe(true)
    expect(checkedFor(wrapper, 'beta')).toBe(false)
  })

  it('toggling a row patches only that skill and re-reads the list', async () => {
    seedWorkspace()
    updateSkillMock.mockResolvedValue({
      skill: {
        name: 'alpha',
        description: 'first',
        content: 'body',
        asset_count: 0,
        is_can_auto_improve: false,
      },
    })

    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()
    const callsAfterLoad = getSkillsMock.mock.calls.length

    await toggleFor(wrapper, 'alpha').setValue(false)
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledWith(WS_ID, 'alpha', { is_can_auto_improve: false })
    expect(getSkillsMock.mock.calls.length).toBeGreaterThan(callsAfterLoad)
    // The checkbox lives inside the row's click target, so without the
    // stop-propagation the user would be thrown into the detail pane.
    expect(wrapper.emitted('selectSkill')).toBeUndefined()
  })

  it('a failed toggle reports the reason instead of silently keeping the new state', async () => {
    seedWorkspace()
    updateSkillMock.mockRejectedValue(new Error('HTTP 404 skill not found'))

    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()

    await toggleFor(wrapper, 'alpha').setValue(false)
    await flushPromises()

    const reported = wrapper.emitted('error')
    expect(reported).toHaveLength(1)
    expect(String(reported?.[0]?.[0])).toContain('HTTP 404 skill not found')
  })

  it('selecting a row still emits the skill name', async () => {
    seedWorkspace()
    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()

    await wrapper.find('[data-skill-name="beta"]').trigger('click')
    expect(wrapper.emitted('selectSkill')).toEqual([['beta']])
  })
})

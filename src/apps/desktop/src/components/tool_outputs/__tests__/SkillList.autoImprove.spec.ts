/*
 * SkillList.vue — the per-row agent lock.
 *
 * The list is the only surface that shows every skill at once, so it is
 * where "which of these may the agent touch?" is answerable.
 *
 * The checkbox used to be on EVERY row — 41 of them on a real workspace,
 * each a PATCH on click, and the loudest thing on screen. It now appears
 * on the row the pointer is on, and always in the detail pane. What must
 * still hold:
 *
 *   1. The row's flag is THAT row's flag — a list that rendered one shared
 *      value would claim a pinned skill is editable.
 *   2. Toggling patches only that skill and re-reads the list.
 *   3. A failed toggle reports the reason instead of silently keeping the
 *      new state.
 *   4. The checkbox never selects the skill: it sits inside the row's
 *      click target, so without stop-propagation a toggle would throw the
 *      user into the detail pane.
 */
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

/** Point at a row, which is what reveals its checkbox. */
const hover = async (wrapper: ReturnType<typeof mount>, skillName: string) => {
  await wrapper.find(`[data-skill-name="${skillName}"]`).trigger('mouseenter')
  await flushPromises()
}

const toggleFor = (wrapper: ReturnType<typeof mount>, skillName: string) =>
  wrapper.find(`[data-skill-name="${skillName}"] [data-testid="skill-auto-improve-toggle"]`)

const checkedFor = (wrapper: ReturnType<typeof mount>, skillName: string) =>
  (toggleFor(wrapper, skillName).element as HTMLInputElement).checked

describe('SkillList — the auto-improve lock', () => {
  it('shows the flag on the row being pointed at, not on all of them', async () => {
    seedWorkspace()
    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()

    // One checkbox for the whole list, not one per row.
    expect(toggles(wrapper)).toHaveLength(0)

    await hover(wrapper, 'alpha')
    expect(toggles(wrapper)).toHaveLength(1)
  })

  it('shows each row its own flag, so a pinned skill is never claimed editable', async () => {
    seedWorkspace()
    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()

    await hover(wrapper, 'alpha')
    expect(checkedFor(wrapper, 'alpha')).toBe(true)

    await hover(wrapper, 'beta')
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

    await hover(wrapper, 'alpha')
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

    await hover(wrapper, 'alpha')
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

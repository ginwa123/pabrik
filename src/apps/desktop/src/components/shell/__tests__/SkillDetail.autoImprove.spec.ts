/** SkillDetail.vue — the agent lock. The companion specs pin reading, deleting and editing. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import SkillDetail from '../SkillDetail.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillDetailMock, deleteSkillMock, updateSkillMock } = vi.hoisted(() => ({
  getSkillDetailMock: vi.fn(),
  deleteSkillMock: vi.fn(),
  updateSkillMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getSkillDetail: getSkillDetailMock,
    deleteSkill: deleteSkillMock,
    updateSkill: updateSkillMock,
  }
})

const WS_ID = 'ws_1'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

function detail(isCanAutoImprove: boolean) {
  return {
    skill: {
      name: 'pdf',
      description: 'convert PDFs to images',
      content: '# pdf skill',
      asset_count: 0,
      is_can_auto_improve: isCanAutoImprove,
      metadata: [],
    },
    error_message: '',
  }
}

const toggleBox = (wrapper: ReturnType<typeof mount>) =>
  wrapper.find('[data-testid="skill-auto-improve-toggle"]').element as HTMLInputElement

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
  updateSkillMock.mockReset()
})

describe('SkillDetail — the auto-improve lock', () => {
  it('renders the stored lock state in read mode, unchecked for a pinned skill', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail(false))

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    // Read mode is where the user finds out the agent is not allowed to
    // touch this skill — hiding the checkbox behind Edit would bury it.
    expect(wrapper.find('[data-testid="skill-auto-improve-toggle"]').exists()).toBe(true)
    expect(toggleBox(wrapper).checked).toBe(false)
  })

  it('unlocking a pinned skill patches the flag and tells the list to re-read', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail(false))
    updateSkillMock.mockResolvedValue({ skill: detail(true).skill })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    await wrapper.find('[data-testid="skill-auto-improve-toggle"]').setValue(true)
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledWith(WS_ID, 'pdf', { is_can_auto_improve: true })
    expect(toggleBox(wrapper).checked).toBe(true)
    // The list row carries its own copy of the flag, so without this the
    // left pane keeps showing the skill as pinned.
    expect(wrapper.emitted('skillSaved')).toEqual([['pdf']])
  })

  it('keeps the lock out of the ordinary edit payload', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail(true))
    updateSkillMock.mockResolvedValue({
      skill: { ...detail(true).skill, description: 'new words' },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await wrapper.find('[data-testid="skill-edit-btn"]').trigger('click')
    await flushPromises()

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('new words')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    // Two fields, no flag: the checkbox owns its own patch, so a Save that
    // also posted the flag could revert a toggle made after the form opened.
    expect(updateSkillMock).toHaveBeenCalledWith(WS_ID, 'pdf', {
      description: 'new words',
      content: '# pdf skill',
    })
  })
})

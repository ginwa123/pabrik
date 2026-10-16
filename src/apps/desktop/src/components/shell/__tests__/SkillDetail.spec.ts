/** SkillDetail.vue — one workspace's skill, read and deleted by name. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import SkillDetail from '../SkillDetail.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillDetailMock, deleteSkillMock } = vi.hoisted(() => ({
  getSkillDetailMock: vi.fn(),
  deleteSkillMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getSkillDetail: getSkillDetailMock,
    deleteSkill: deleteSkillMock,
  }
})

const WS_ID = 'ws_1'
const WS_OTHER = 'ws_2'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

function detail(overrides: Record<string, unknown> = {}) {
  return {
    skill: {
      name: 'pdf',
      description: 'convert PDFs to images',
      content: '# pdf skill',
      asset_count: 11,
      ...overrides,
    },
    error_message: '',
  }
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
})

describe('SkillDetail — reading a skill', () => {
  it('loads with the resolved workspace id and the name', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    expect(useWorkspacesStore().activeWorkspaceId).toBeNull()
    expect(getSkillDetailMock).toHaveBeenCalledWith(WS_ID, 'pdf')
  })

  it('renders the name, description and content', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    const text = wrapper.text()
    expect(text).toContain('pdf')
    expect(text).toContain('convert PDFs to images')
    expect(text).toContain('# pdf skill')
  })

  it('shows the companion-file count for a bundle and hides it at zero', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail({ asset_count: 11 }))
    const bundled = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    expect(bundled.find('[data-testid="skill-detail-assets"]').text()).toContain('11')

    getSkillDetailMock.mockResolvedValue(detail({ asset_count: 1 }))
    const single = mount(SkillDetail, { props: { skillName: 'solo' } })
    await flushPromises()
    expect(single.find('[data-testid="skill-detail-assets"]').text()).toContain('1 bundled file')

    getSkillDetailMock.mockResolvedValue(detail({ asset_count: 0 }))
    const plain = mount(SkillDetail, { props: { skillName: 'plain' } })
    await flushPromises()
    expect(plain.find('[data-testid="skill-detail-assets"]').exists()).toBe(false)
  })

  it('treats a missing asset_count as zero rather than rendering NaN', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue({
      skill: { name: 'pdf', description: 'd', content: 'c' },
      error_message: '',
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-detail-assets"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('NaN')
  })

  it('never renders a path or a (global) badge', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue({
      skill: {
        name: 'pdf',
        description: 'd',
        content: 'c',
        asset_count: 0,
        // Left over from a pre-refactor payload.
        path: '/g/pdf/SKILL.MD',
        is_global: true,
      },
      error_message: '',
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    expect(wrapper.text()).not.toContain('/g/pdf/SKILL.MD')
    expect(wrapper.text()).not.toContain('(global)')
    expect(wrapper.text()).not.toContain('Path:')
  })

  it('prompts when nothing is selected and fetches nothing', async () => {
    seedWorkspace()
    const wrapper = mount(SkillDetail, { props: { skillName: null } })
    await flushPromises()

    expect(getSkillDetailMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skill-detail-empty"]').exists()).toBe(true)
  })

  it('renders a failed request as a failure, not as an empty skill', async () => {
    seedWorkspace()
    getSkillDetailMock.mockRejectedValue(new Error('HTTP 503'))

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-detail-error"]').text()).toContain('HTTP 503')
    expect(wrapper.text()).not.toContain('Content')
  })

  it('renders the backend refusal from error_message', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue({
      skill: null,
      error_message: 'skill not in this workspace',
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'ghost' } })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-detail-error"]').text()).toContain(
      'skill not in this workspace',
    )
  })

  it('says "not found" when the payload has neither a skill nor a reason', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue({ skill: null, error_message: '' })

    const wrapper = mount(SkillDetail, { props: { skillName: 'ghost' } })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-detail-error"]').text()).toContain('not found')
  })
})

describe('SkillDetail — deleting', () => {
  /** Clicks the trash icon, then confirms in the modal. */
  async function deleteVia(wrapper: ReturnType<typeof mount>): Promise<void> {
    await wrapper.find('button[title="Delete skill"]').trigger('click')
    const confirm = wrapper.findAll('button').find((b) => b.text() === 'Delete')
    await confirm!.trigger('click')
    await flushPromises()
  }

  it('deletes by (workspaceId, name) with no is_global argument', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    deleteSkillMock.mockResolvedValue({ success: true, skill_name: 'pdf', error_message: '' })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await deleteVia(wrapper)

    expect(deleteSkillMock).toHaveBeenCalledTimes(1)
    expect(deleteSkillMock).toHaveBeenCalledWith(WS_ID, 'pdf')
    expect(deleteSkillMock.mock.calls[0]).toHaveLength(2)
    expect(wrapper.emitted('skillDeleted')).toEqual([['pdf']])
  })

  it('deletes in the workspace that is active when the button is pressed', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
      { id: WS_OTHER, name: 'Second', icon: '📁', items: [], expanded: true } satisfies Workspace,
    ]
    getSkillDetailMock.mockResolvedValue(detail())
    deleteSkillMock.mockResolvedValue({ success: true, skill_name: 'pdf', error_message: '' })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    store.setActiveWorkspace(WS_OTHER)
    // The switch re-runs the load; let it settle before clicking, or the
    // panel is mid-fetch and the delete button is not on screen.
    await flushPromises()
    await deleteVia(wrapper)

    expect(deleteSkillMock).toHaveBeenCalledWith(WS_OTHER, 'pdf')
  })

  it('emits the backend refusal instead of claiming a deletion', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    deleteSkillMock.mockResolvedValue({
      success: false,
      skill_name: 'pdf',
      error_message: 'skill is in use',
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await deleteVia(wrapper)

    expect(wrapper.emitted('skillDeleted')).toBeUndefined()
    expect(wrapper.emitted('error')).toEqual([['skill is in use']])
  })

  it('emits a thrown failure rather than swallowing it', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    deleteSkillMock.mockRejectedValue(new Error('HTTP 500'))

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await deleteVia(wrapper)

    expect(wrapper.emitted('skillDeleted')).toBeUndefined()
    expect(String(wrapper.emitted('error')?.[0]?.[0])).toContain('HTTP 500')
  })

  it('cancel does not delete', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await wrapper.find('button[title="Delete skill"]').trigger('click')
    const cancel = wrapper.findAll('button').find((b) => b.text() === 'Cancel')
    await cancel!.trigger('click')
    await flushPromises()

    expect(deleteSkillMock).not.toHaveBeenCalled()
  })
})

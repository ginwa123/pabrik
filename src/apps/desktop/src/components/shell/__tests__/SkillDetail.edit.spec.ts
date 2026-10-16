/** SkillDetail.vue — the edit path. The companion file (`SkillDetail.spec.ts`) pins reading and
 * deleting. This one pins the two things an edit can get wrong that a read cannot: 1. A patch that
 * mentions only ONE field must not blank the other. */
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

function detail(overrides: Record<string, unknown> = {}) {
  return {
    skill: {
      name: 'pdf',
      description: 'convert PDFs to images',
      content: '# pdf skill',
      asset_count: 0,
      ...overrides,
    },
    error_message: '',
  }
}

/** Click Edit, then wait for the form to be seeded from the loaded row. */
async function openEditor(wrapper: ReturnType<typeof mount>): Promise<void> {
  await wrapper.find('[data-testid="skill-edit-btn"]').trigger('click')
  await flushPromises()
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
  updateSkillMock.mockReset()
})

describe('SkillDetail — editing', () => {
  it('opens the form seeded from the loaded row, not blank', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    // A blank form would make the first Save a no-op patch the server
    // refuses with 409 — the user would have to retype everything.
    expect(
      (wrapper.find('[data-testid="skill-edit-description"]').element as HTMLInputElement).value,
    ).toBe('convert PDFs to images')
    expect(
      (wrapper.find('[data-testid="skill-edit-content"]').element as HTMLTextAreaElement).value,
    ).toBe('# pdf skill')
  })

  it('offers no name field — the name is the use_skill argument', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    // A rename would break every `use_skill({ name })` call and every
    // cached `skill_eval` verdict, so the form does not carry the field
    // at all rather than carrying a disabled one.
    const inputs = wrapper.findAll('input')
    expect(inputs.some((i) => (i.element as HTMLInputElement).value === 'pdf')).toBe(false)
    expect(wrapper.text()).toContain('name is fixed')
  })

  it('sends BOTH fields, so a description-only edit cannot blank the body', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    updateSkillMock.mockResolvedValue({
      skill: { name: 'pdf', description: 'new words', content: '# pdf skill', asset_count: 0 },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('new words')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledTimes(1)
    expect(updateSkillMock).toHaveBeenCalledWith(WS_ID, 'pdf', {
      description: 'new words',
      content: '# pdf skill',
    })
  })

  it('sends the edited body and keeps the description it did not touch', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    updateSkillMock.mockResolvedValue({
      skill: {
        name: 'pdf',
        description: 'convert PDFs to images',
        content: '# new body',
        asset_count: 0,
      },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-content"]').setValue('# new body')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledWith(WS_ID, 'pdf', {
      description: 'convert PDFs to images',
      content: '# new body',
    })
  })

  it('renders the STORED row after a save, not what was typed', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    // The server is the authority: it trims, and it is what the next read
    // returns. Rendering the draft instead would show text that is not
    // actually in the database.
    updateSkillMock.mockResolvedValue({
      skill: {
        name: 'pdf',
        description: 'trimmed by the server',
        content: '# pdf skill',
        asset_count: 0,
      },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('  padded  ')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    expect(wrapper.text()).toContain('trimmed by the server')
    expect(wrapper.text()).not.toContain('padded')
    // Back to read-only: the form is gone.
    expect(wrapper.find('[data-testid="skill-edit-content"]').exists()).toBe(false)
  })

  it('emits skillSaved so the list can re-read the description', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    updateSkillMock.mockResolvedValue({
      skill: { name: 'pdf', description: 'new words', content: '# pdf skill', asset_count: 0 },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('new words')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    // The description is the list row's second line. Without this the two
    // halves disagree about the same skill until a reload.
    expect(wrapper.emitted('skillSaved')).toEqual([['pdf']])
  })

  it('disables Save until something actually changed', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    // The server answers 409 to a no-op patch, so an enabled Save here
    // would be a button whose only outcome is an error.
    const save = wrapper.find('[data-testid="skill-edit-save"]')
    expect((save.element as HTMLButtonElement).disabled).toBe(true)

    await wrapper.find('[data-testid="skill-edit-content"]').setValue('# changed')
    await flushPromises()
    expect((save.element as HTMLButtonElement).disabled).toBe(false)
  })

  it('re-enables Save when a field is changed back to a DIFFERENT value', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    const save = wrapper.find('[data-testid="skill-edit-save"]')
    await wrapper.find('[data-testid="skill-edit-description"]').setValue('one')
    await flushPromises()
    expect((save.element as HTMLButtonElement).disabled).toBe(false)

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('two')
    await flushPromises()
    expect((save.element as HTMLButtonElement).disabled).toBe(false)
  })

  it('keeps a backend refusal in the form instead of emitting a toast', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())
    updateSkillMock.mockRejectedValue(new Error('HTTP 409 nothing to change'))

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-content"]').setValue('# changed')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    // The user is mid-edit: the reason belongs beside the fields that
    // caused it, and the form must stay open with the draft intact.
    expect(wrapper.find('[data-testid="skill-save-error"]').text()).toContain('HTTP 409')
    expect(wrapper.emitted('error')).toBeUndefined()
    expect(wrapper.find('[data-testid="skill-edit-content"]').exists()).toBe(true)
    expect(
      (wrapper.find('[data-testid="skill-edit-content"]').element as HTMLTextAreaElement).value,
    ).toBe('# changed')
  })

  it('cancel discards the draft and leaves the stored row on screen', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-content"]').setValue('# half-typed')
    await wrapper.find('[data-testid="skill-edit-cancel"]').trigger('click')
    await flushPromises()

    expect(updateSkillMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skill-edit-content"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('# pdf skill')
    expect(wrapper.text()).not.toContain('half-typed')
  })

  it('re-opening the form re-seeds from the row, not from the abandoned draft', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail())

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-content"]').setValue('# abandoned')
    await wrapper.find('[data-testid="skill-edit-cancel"]').trigger('click')
    await flushPromises()
    await openEditor(wrapper)

    expect(
      (wrapper.find('[data-testid="skill-edit-content"]').element as HTMLTextAreaElement).value,
    ).toBe('# pdf skill')
  })

  it('edits in the workspace that is active when Save is pressed', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: 'ws_1', name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
      { id: 'ws_2', name: 'Second', icon: '📁', items: [], expanded: true } satisfies Workspace,
    ]
    getSkillDetailMock.mockResolvedValue(detail())
    updateSkillMock.mockResolvedValue({
      skill: { name: 'pdf', description: 'new words', content: '# pdf skill', asset_count: 0 },
    })

    const wrapper = mount(SkillDetail, { props: { skillName: 'pdf' } })
    await flushPromises()
    store.setActiveWorkspace('ws_2')
    await flushPromises()
    await openEditor(wrapper)

    await wrapper.find('[data-testid="skill-edit-description"]').setValue('new words')
    await wrapper.find('[data-testid="skill-edit-save"]').trigger('click')
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledWith('ws_2', 'pdf', {
      description: 'new words',
      content: '# pdf skill',
    })
  })
})

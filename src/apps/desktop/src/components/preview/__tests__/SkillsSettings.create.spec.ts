/** SkillsSettings.vue — the create path. The panel was read-only + delete; this pins the insert
 * half. The assertions that matter are the ones a read-only panel could not get wrong: 1. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import SkillsSettings from '../SkillsSettings.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillsMock, createSkillMock, getSkillDetailMock, deleteSkillMock } = vi.hoisted(() => ({
  getSkillsMock: vi.fn(),
  createSkillMock: vi.fn(),
  getSkillDetailMock: vi.fn(),
  deleteSkillMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getSkills: getSkillsMock,
    createSkill: createSkillMock,
    getSkillDetail: getSkillDetailMock,
    deleteSkill: deleteSkillMock,
  }
})

const WS_ID = 'ws_1'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

/** Click "New skill", then wait for the form to mount. */
async function openCreateForm(wrapper: ReturnType<typeof mount>): Promise<void> {
  await wrapper.find('[data-testid="new-skill-btn"]').trigger('click')
  await flushPromises()
}

/** Fill the three fields and press Create. */
async function submit(
  wrapper: ReturnType<typeof mount>,
  fields: { name: string; description?: string; content?: string },
): Promise<void> {
  await wrapper.find('[data-testid="new-skill-name"]').setValue(fields.name)
  if (fields.description !== undefined) {
    await wrapper.find('[data-testid="new-skill-description"]').setValue(fields.description)
  }
  if (fields.content !== undefined) {
    await wrapper.find('[data-testid="new-skill-content"]').setValue(fields.content)
  }
  await wrapper.find('[data-testid="new-skill-save"]').trigger('click')
  await flushPromises()
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillsMock.mockReset()
  createSkillMock.mockReset()
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
  // The list half loads on mount; keep it quiet and empty.
  getSkillsMock.mockResolvedValue({ skills: [] })
  getSkillDetailMock.mockResolvedValue({ skill: null, error_message: '' })
})

describe('SkillsSettings — creating a skill', () => {
  it('opens a blank form and hides the detail pane', async () => {
    seedWorkspace()
    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-create-form"]').exists()).toBe(false)

    await openCreateForm(wrapper)

    expect(wrapper.find('[data-testid="skill-create-form"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-detail"]').exists()).toBe(false)
    // Blank, not seeded from whatever was selected before.
    expect((wrapper.find('[data-testid="new-skill-name"]').element as HTMLInputElement).value).toBe(
      '',
    )
  })

  it('posts all three fields, so a name-only create leaves no NULL behind', async () => {
    seedWorkspace()
    createSkillMock.mockResolvedValue({
      skill: { name: 'my-skill', description: 'When to use it', content: 'body', asset_count: 0 },
    })

    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)
    await submit(wrapper, {
      name: 'my-skill',
      description: 'When to use it',
      content: 'body',
    })

    expect(createSkillMock).toHaveBeenCalledTimes(1)
    expect(createSkillMock).toHaveBeenCalledWith(WS_ID, {
      name: 'my-skill',
      description: 'When to use it',
      content: 'body',
    })
  })

  it('trims the name before posting', async () => {
    seedWorkspace()
    createSkillMock.mockResolvedValue({
      skill: { name: 'my-skill', description: '', content: '', asset_count: 0 },
    })

    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)
    await submit(wrapper, { name: '  my-skill  ' })

    // The name is the UNIQUE key and the URL path segment, so a padded
    // name would create a row nobody can address.
    expect(createSkillMock).toHaveBeenCalledWith(WS_ID, {
      name: 'my-skill',
      description: '',
      content: '',
    })
  })

  it('disables Create until a name is typed', async () => {
    seedWorkspace()
    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)

    const save = wrapper.find('[data-testid="new-skill-save"]')
    expect((save.element as HTMLButtonElement).disabled).toBe(true)

    await wrapper.find('[data-testid="new-skill-name"]').setValue('x')
    await flushPromises()
    expect((save.element as HTMLButtonElement).disabled).toBe(false)
  })

  it('selects the new row and re-reads the list after a create', async () => {
    seedWorkspace()
    createSkillMock.mockResolvedValue({
      skill: { name: 'my-skill', description: 'When to use it', content: 'body', asset_count: 0 },
    })

    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)
    await submit(wrapper, { name: 'my-skill', description: 'When to use it', content: 'body' })

    // The form closes and the detail pane shows the row that was stored.
    expect(wrapper.find('[data-testid="skill-create-form"]').exists()).toBe(false)
    expect(getSkillDetailMock).toHaveBeenCalledWith(WS_ID, 'my-skill')
    // The list re-reads, so the new row appears in the left pane.
    expect(getSkillsMock.mock.calls.length).toBeGreaterThan(1)
    expect(wrapper.emitted('notification')).toEqual([['Skill "my-skill" created', 'success']])
  })

  it('shows a duplicate-name refusal in the form and keeps the draft', async () => {
    seedWorkspace()
    createSkillMock.mockRejectedValue(new Error('HTTP 409 a skill named'))

    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)
    await submit(wrapper, { name: 'pdf', description: 'dupe', content: 'body' })

    // The user is mid-entry: the reason belongs beside the fields, and the
    // form must stay open with what they typed.
    expect(wrapper.find('[data-testid="skill-create-error"]').text()).toContain('HTTP 409')
    expect(wrapper.find('[data-testid="skill-create-form"]').exists()).toBe(true)
    expect((wrapper.find('[data-testid="new-skill-name"]').element as HTMLInputElement).value).toBe(
      'pdf',
    )
    expect(wrapper.emitted('notification')).toBeUndefined()
  })

  it('cancel closes the form and posts nothing', async () => {
    seedWorkspace()
    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)

    await wrapper.find('[data-testid="new-skill-name"]').setValue('half-typed')
    await wrapper.find('[data-testid="new-skill-cancel"]').trigger('click')
    await flushPromises()

    expect(createSkillMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skill-create-form"]').exists()).toBe(false)
  })

  it('re-opening the form starts blank, not from the abandoned draft', async () => {
    seedWorkspace()
    const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
    await flushPromises()
    await openCreateForm(wrapper)

    await wrapper.find('[data-testid="new-skill-name"]').setValue('abandoned')
    await wrapper.find('[data-testid="new-skill-cancel"]').trigger('click')
    await flushPromises()
    await openCreateForm(wrapper)

    expect((wrapper.find('[data-testid="new-skill-name"]').element as HTMLInputElement).value).toBe(
      '',
    )
  })

  it('creates in the workspace the page is bound to, not the active one', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: 'ws_1', name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
      { id: 'ws_2', name: 'Second', icon: '📁', items: [], expanded: true } satisfies Workspace,
    ]
    createSkillMock.mockResolvedValue({
      skill: { name: 'my-skill', description: '', content: '', asset_count: 0 },
    })

    // The settings page binds the ROUTE workspace, which may differ from
    // the active one. A create that used the active workspace would put
    // the row somewhere the user is not looking.
    const wrapper = mount(SkillsSettings, { props: { workspaceId: 'ws_2' } })
    await flushPromises()
    await openCreateForm(wrapper)
    await submit(wrapper, { name: 'my-skill' })

    expect(createSkillMock).toHaveBeenCalledWith('ws_2', expect.anything())
  })
})

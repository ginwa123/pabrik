/** SkillDetail.vue — the body's outline and find box, and their absence in
 * edit mode where the textarea owns the pane. */
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

const BODY = [
  '---',
  'name: my-skill',
  '---',
  '',
  '## When to Use',
  '',
  'Load this when the task is about tests.',
  '',
  '## Procedure',
  '',
  '### Write the test first',
  '',
  'Run `zig build test`.',
  '',
  '## Pitfalls',
  '',
  'A flaky test is a hidden input.',
  '',
].join('\n')

function seedWorkspace(): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id: WS_ID, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

async function mountDetail(): Promise<ReturnType<typeof mount>> {
  const wrapper = mount(SkillDetail, {
    props: { skillName: 'my-skill', workspaceId: WS_ID },
  })
  await flushPromises()
  await flushPromises()
  return wrapper
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
  updateSkillMock.mockReset()
  getSkillDetailMock.mockResolvedValue({
    skill: {
      name: 'my-skill',
      description: 'When to use it',
      content: BODY,
      asset_count: 0,
      is_can_auto_improve: true,
      metadata: [],
    },
    error_message: '',
  })
})

describe('SkillDetail — the outline', () => {
  it('lists the ## and ### headings of the body', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()

    const nav = wrapper.find('[data-testid="skill-body-nav"]')
    expect(nav.exists()).toBe(true)
    expect(nav.text()).toContain('When to Use')
    expect(nav.text()).toContain('Procedure')
    expect(nav.text()).toContain('Write the test first')
    expect(nav.text()).toContain('Pitfalls')
  })

  it('does not list the frontmatter title', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    // `name: my-skill` is a level-1 line inside the frontmatter fence.
    expect(wrapper.find('[data-testid="skill-body-nav"]').text()).not.toContain('my-skill')
  })

  it('renders one addressable row per body line', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()

    // A jump needs somewhere to land, so every line carries its number.
    const lines = wrapper.findAll('[data-body-line]')
    expect(lines.length).toBe(BODY.split('\n').length)
    expect(lines[4]!.attributes('data-body-line')).toBe('5')
  })

  it('shows no outline for a body with no headings', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue({
      skill: {
        name: 'my-skill',
        description: '',
        content: 'just prose',
        asset_count: 0,
        is_can_auto_improve: true,
        metadata: [],
      },
      error_message: '',
    })
    const wrapper = await mountDetail()

    expect(wrapper.find('[data-testid="skill-body-nav"]').exists()).toBe(false)
  })
})

describe('SkillDetail — finding text in the body', () => {
  it('lists every line containing the term', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    await wrapper.find('[data-testid="skill-body-find"]').setValue('test')
    await flushPromises()

    const hits = wrapper.find('[data-testid="skill-body-hits"]')
    expect(hits.exists()).toBe(true)
    expect(hits.text()).toContain('matches')
    // Four lines of the fixture body contain "test".
    expect(wrapper.findAll('[data-testid^="skill-body-hit-"]').length).toBe(4)
  })

  it('highlights the matching lines in the body', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    await wrapper.find('[data-testid="skill-body-find"]').setValue('flaky')
    await flushPromises()

    const highlighted = wrapper.findAll('.body-line-hit')
    expect(highlighted.length).toBe(1)
    expect(highlighted[0]!.text()).toContain('A flaky test is a hidden input.')
  })

  it('says nothing matched, rather than showing an empty list', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    await wrapper.find('[data-testid="skill-body-find"]').setValue('kubernetes')
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-body-hits"]').exists()).toBe(false)
    expect(wrapper.findAll('.body-line-hit').length).toBe(0)
  })

  it('clears the term and the highlights on Escape', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    const input = wrapper.find('[data-testid="skill-body-find"]')
    await input.setValue('flaky')
    await flushPromises()
    expect(wrapper.findAll('.body-line-hit').length).toBe(1)

    await input.trigger('keydown', { key: 'Escape' })
    await flushPromises()
    expect(wrapper.findAll('.body-line-hit').length).toBe(0)
  })
})

describe('SkillDetail — edit mode owns the pane', () => {
  it('hides the find box and the outline while editing', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    await wrapper.find('[data-testid="skill-edit-btn"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-body-find"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="skill-body-nav"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="skill-edit-content"]').exists()).toBe(true)
  })

  it('brings them back when the edit is cancelled', async () => {
    seedWorkspace()
    const wrapper = await mountDetail()
    await wrapper.find('[data-testid="skill-edit-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="skill-edit-cancel"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-body-find"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-body-nav"]').exists()).toBe(true)
  })
})

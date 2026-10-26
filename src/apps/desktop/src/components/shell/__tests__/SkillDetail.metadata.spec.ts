/** SkillDetail.vue — the frontmatter metadata strip: it renders `skill_metadata` rows and never
 * re-parses the `---` fence out of `content`, so a body full of keys with an empty read renders
 * nothing. */
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
  'description: Work with PDFs.',
  'origin: ECC',
  'tags: [workflow, documents]',
  'license: MIT',
  '---',
  '',
  '## When to Use',
  '',
  'Always.',
  '',
].join('\n')

function seedWorkspace(): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id: WS_ID, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

function detail(metadata: { key: string; value: string }[]) {
  return {
    skill: {
      name: 'my-skill',
      description: 'Work with PDFs.',
      content: BODY,
      asset_count: 0,
      is_can_auto_improve: true,
      metadata,
    },
    error_message: '',
  }
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
})

describe('SkillDetail — frontmatter metadata', () => {
  it('renders one chip per metadata key, key and value both readable', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(
      detail([
        { key: 'license', value: 'MIT' },
        { key: 'origin', value: 'ECC' },
        { key: 'tags', value: '[workflow, documents]' },
      ]),
    )
    const wrapper = await mountDetail()

    const strip = wrapper.find('[data-testid="skill-detail-metadata"]')
    expect(strip.exists()).toBe(true)
    expect(strip.findAll('span[data-testid^="skill-metadata-"]').length).toBe(3)
    expect(wrapper.find('[data-testid="skill-metadata-origin"]').text()).toContain('origin')
    expect(wrapper.find('[data-testid="skill-metadata-origin"]').text()).toContain('ECC')
    expect(wrapper.find('[data-testid="skill-metadata-license"]').text()).toContain('MIT')
    expect(wrapper.find('[data-testid="skill-metadata-tags"]').text()).toContain(
      '[workflow, documents]',
    )
  })

  it('renders no strip at all when the read reports no metadata', async () => {
    seedWorkspace()
    // The body STILL carries `origin`/`tags`. Rendering them here would mean
    // this pane had re-parsed the fence, which is the thing the table exists
    // to stop.
    getSkillDetailMock.mockResolvedValue(detail([]))
    const wrapper = await mountDetail()

    expect(wrapper.find('[data-testid="skill-detail-metadata"]').exists()).toBe(false)
  })

  it('keeps every name and description out of the metadata strip', async () => {
    seedWorkspace()
    getSkillDetailMock.mockResolvedValue(detail([{ key: 'origin', value: 'ECC' }]))
    const wrapper = await mountDetail()

    const strip = wrapper.find('[data-testid="skill-detail-metadata"]').text()
    expect(strip).not.toContain('my-skill')
    expect(strip).not.toContain('Work with PDFs.')
  })
})

/** SkillsSettings.vue — the selected skill in the URL. The router is mocked
 * at the boundary; the assertions read the navigation calls. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useRoute, useRouter } from 'vue-router'
import SkillsSettings from '../SkillsSettings.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'

const { getSkillsMock, getSkillDetailMock, deleteSkillMock, createSkillMock, replaceMock } =
  vi.hoisted(() => ({
    getSkillsMock: vi.fn(),
    getSkillDetailMock: vi.fn(),
    deleteSkillMock: vi.fn(),
    createSkillMock: vi.fn(),
    replaceMock: vi.fn(),
  }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getSkills: getSkillsMock,
    getSkillDetail: getSkillDetailMock,
    deleteSkill: deleteSkillMock,
    createSkill: createSkillMock,
  }
})

vi.mock('vue-router', () => ({
  useRoute: vi.fn(),
  useRouter: vi.fn(),
}))

const WS_ID = 'ws_1'

const SKILL = {
  name: 'behavior-unit-tests',
  description: 'Write deterministic unit tests',
  content: 'body',
  asset_count: 0,
  is_can_auto_improve: false,
  metadata: [],
}

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

/** Mount with a given query string, as the router would hand it over. */
async function mountWithQuery(query: Record<string, string>): Promise<ReturnType<typeof mount>> {
  vi.mocked(useRoute).mockReturnValue({
    path: `/app/${WS_ID}/settings`,
    query,
  } as unknown as ReturnType<typeof useRoute>)
  vi.mocked(useRouter).mockReturnValue({
    replace: replaceMock,
  } as unknown as ReturnType<typeof useRouter>)

  const wrapper = mount(SkillsSettings, { props: { workspaceId: WS_ID } })
  await flushPromises()
  return wrapper
}

/** The query object of the most recent `router.replace` call. */
function lastReplaceQuery(): Record<string, string> {
  const call = replaceMock.mock.calls.at(-1)
  return (call?.[0] as { query?: Record<string, string> })?.query ?? {}
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillsMock.mockReset()
  getSkillDetailMock.mockReset()
  deleteSkillMock.mockReset()
  createSkillMock.mockReset()
  replaceMock.mockReset()
  getSkillsMock.mockResolvedValue({
    skills: [{ name: SKILL.name, description: SKILL.description, is_can_auto_improve: false }],
  })
  getSkillDetailMock.mockResolvedValue({ skill: SKILL, error_message: '' })
})

describe('SkillsSettings — the selected skill is a URL param', () => {
  it('reads the selection from ?skill= on mount', async () => {
    seedWorkspace()
    await mountWithQuery({ skill: 'behavior-unit-tests' })

    // The detail pane loads the row the URL names, so a refresh or a
    // shared link lands on the same skill.
    expect(getSkillDetailMock).toHaveBeenCalledWith(WS_ID, 'behavior-unit-tests')
  })

  it('writes ?skill= when a row is clicked', async () => {
    seedWorkspace()
    const wrapper = await mountWithQuery({})
    replaceMock.mockClear()

    await wrapper.find('[data-skill-name="behavior-unit-tests"]').trigger('click')
    await flushPromises()

    expect(lastReplaceQuery().skill).toBe('behavior-unit-tests')
  })

  it('keeps the other query params when it writes the selection', async () => {
    seedWorkspace()
    // A query that keeps the row on screen — the list honours `?q=` on
    // mount, so a query that excluded the row would leave nothing to click.
    const wrapper = await mountWithQuery({ section: 'skills', q: 'behavior' })
    replaceMock.mockClear()

    await wrapper.find('[data-skill-name="behavior-unit-tests"]').trigger('click')
    await flushPromises()

    // `section` is what keeps this page on the Skills tab; dropping it
    // would navigate the user somewhere else entirely.
    const query = lastReplaceQuery()
    expect(query.section).toBe('skills')
    expect(query.q).toBe('behavior')
    expect(query.skill).toBe('behavior-unit-tests')
  })

  it('clears ?skill= when the skill is deleted', async () => {
    seedWorkspace()
    deleteSkillMock.mockResolvedValue({ success: true, skill_name: SKILL.name, error_message: '' })
    const wrapper = await mountWithQuery({ skill: 'behavior-unit-tests' })
    replaceMock.mockClear()

    await wrapper.find('button[title="Delete skill"]').trigger('click')
    await flushPromises()
    const confirm = wrapper.findAll('button').find((b) => b.text() === 'Delete')
    await confirm?.trigger('click')
    await flushPromises()

    expect(lastReplaceQuery().skill).toBeUndefined()
  })

  it('writes ?skill= for the row it just created', async () => {
    seedWorkspace()
    const wrapper = await mountWithQuery({})
    replaceMock.mockClear()

    createSkillMock.mockResolvedValue({
      skill: {
        name: 'my-skill',
        description: '',
        content: '',
        asset_count: 0,
        is_can_auto_improve: true,
        metadata: [],
      },
    })
    await wrapper.find('[data-testid="new-skill-btn"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="new-skill-name"]').setValue('my-skill')
    await wrapper.find('[data-testid="new-skill-save"]').trigger('click')
    await flushPromises()

    expect(lastReplaceQuery().skill).toBe('my-skill')
  })
})

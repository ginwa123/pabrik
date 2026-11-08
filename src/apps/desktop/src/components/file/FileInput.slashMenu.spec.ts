import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from './FileInput.vue'
import * as api from '../../api'
import { useWorkspacesStore, type Workspace } from '../../stores/workspaces'

vi.mock('../../api', () => ({
  API_BASE: '/api',
  searchFiles: vi.fn(),
  getSkills: vi.fn(),
  getAgentToolsRegistry: vi.fn(),
}))

const getSkillsMock = api.getSkills as unknown as ReturnType<typeof vi.fn>
const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>
const getRegistryMock = api.getAgentToolsRegistry as unknown as ReturnType<typeof vi.fn>

const WS_ID = 'ws_1'
const MENU = '[data-testid="slash-command-menu"]'
const SKILL_PICKER = '[data-testid="skill-picker-list"]'
const TOOL_PICKER = '[data-testid="tool-picker-list"]'
const FILE_PICKER = '.file-picker-list'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
  waitMs = 450,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  await new Promise((resolve) => setTimeout(resolve, waitMs))
  await flushPromises()
}

function menuRows(wrapper: VueWrapper) {
  return wrapper.find(MENU).findAll('button')
}

describe('FileInput — slash command menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    getSkillsMock.mockReset()
    searchFilesMock.mockReset()
    getRegistryMock.mockReset()
    getSkillsMock.mockResolvedValue({ skills: [{ name: 'review', description: 'reviews code' }] })
    getRegistryMock.mockResolvedValue({
      tools: [{ name: 'read_file', description: 'reads a file' }],
    })
    searchFilesMock.mockResolvedValue({ entries: [{ path: 'src/main.ts', isDirectory: false }] })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("a bare '/' lists the skill, tool and file commands", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/')

    expect(wrapper.find(MENU).exists()).toBe(true)
    const rows = menuRows(wrapper)
    expect(rows).toHaveLength(3)
    expect(rows.map((r) => r.text())).toEqual([
      expect.stringContaining('/skill-'),
      expect.stringContaining('/tool-'),
      expect.stringContaining('/files-'),
    ])
  })

  it('opening the menu fetches nothing', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/')

    expect(getSkillsMock).not.toHaveBeenCalled()
    expect(getRegistryMock).not.toHaveBeenCalled()
    expect(searchFilesMock).not.toHaveBeenCalled()
  })

  it("typing '/f' narrows the menu to the file command", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/f')

    const rows = menuRows(wrapper)
    expect(rows).toHaveLength(1)
    expect(rows[0]!.text()).toContain('/files-')
  })

  it("typing '/z' closes the menu because no command matches", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/z')

    expect(wrapper.find(MENU).exists()).toBe(false)
  })

  it("a '/' inside a word does not open the menu", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), 'a/b')

    expect(wrapper.find(MENU).exists()).toBe(false)
  })

  it("a '/' after prose opens the menu", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), 'please run /')

    expect(wrapper.find(MENU).exists()).toBe(true)
    expect(menuRows(wrapper)).toHaveLength(3)
  })

  it('Enter on the first row completes /skill- and opens the skill picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/skill-')
    expect(wrapper.find(MENU).exists()).toBe(false)
    expect(wrapper.find(SKILL_PICKER).exists()).toBe(true)
  })

  it('ArrowDown then Enter completes /tool- and opens the tool picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await textarea.trigger('keydown', { key: 'ArrowDown' })
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/tool-')
    expect(wrapper.find(TOOL_PICKER).exists()).toBe(true)
  })

  it('ArrowUp from the first row stays on the first row', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await textarea.trigger('keydown', { key: 'ArrowUp' })
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/skill-')
  })

  it('Tab completes the highlighted command', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await textarea.trigger('keydown', { key: 'ArrowDown' })
    await textarea.trigger('keydown', { key: 'ArrowDown' })
    await textarea.trigger('keydown', { key: 'Tab' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/files-')
    expect(wrapper.find(FILE_PICKER).exists()).toBe(true)
  })

  it('clicking the file row completes /files- and opens the file picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await wrapper.find('[data-testid="slash-command-files-"]').trigger('click')
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/files-')
    expect(wrapper.find(MENU).exists()).toBe(false)
    expect(wrapper.find(FILE_PICKER).exists()).toBe(true)
  })

  it('Esc dismisses the menu and leaves the typed text alone', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')
    expect(wrapper.find(MENU).exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()

    expect(wrapper.find(MENU).exists()).toBe(false)
    expect((textarea.element as HTMLTextAreaElement).value).toBe('/')
  })

  it('Enter on the menu never sends the message', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect(wrapper.emitted('submit')).toBeUndefined()
  })

  it('the menu and a picker never render at once', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, '/')
    expect(wrapper.find(MENU).exists()).toBe(true)
    expect(wrapper.find(SKILL_PICKER).exists()).toBe(false)

    await typeInTextarea(textarea, '/skill-')
    expect(wrapper.find(MENU).exists()).toBe(false)
    expect(wrapper.find(SKILL_PICKER).exists()).toBe(true)

    await typeInTextarea(textarea, '/')
    expect(wrapper.find(MENU).exists()).toBe(true)
    expect(wrapper.find(SKILL_PICKER).exists()).toBe(false)
  })

  it('completing keeps the prose that preceded the token', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, 'please run /')

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('please run /skill-')
  })
})

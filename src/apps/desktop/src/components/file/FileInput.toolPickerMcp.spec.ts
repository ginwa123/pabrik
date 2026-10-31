/** FileInput `/tool-` picker — the MCP rows the registry can now return. */
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

const MCP_NAME = 'mcp_ctx_query-docs'

function seedWorkspace(id = 'ws_1'): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

/** The wire shape the endpoint returns once MCP tools are included. */
function registryWithMcpTool() {
  return {
    tools: [
      { name: 'read_file', description: 'reads a file', kind: 'builtin' as const },
      {
        name: MCP_NAME,
        description: 'Query library documentation.',
        kind: 'mcp' as const,
      },
    ],
  }
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

/** Same 150ms detect debounce the picker's own spec waits out. */
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

describe('FileInput — /tool picker MCP rows', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    getSkillsMock.mockReset()
    searchFilesMock.mockReset()
    getRegistryMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
    getSkillsMock.mockResolvedValue({ skills: [] })
    getRegistryMock.mockResolvedValue(registryWithMcpTool())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('lists a server tool, badges it, and inserts its wire name', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, '/tool-mcp')

    const list = wrapper.find('[data-testid="tool-picker-list"]')
    expect(list.text()).toContain(MCP_NAME)
    expect(list.text()).not.toContain('read_file')

    const row = wrapper.find(`[data-tool-name="${MCP_NAME}"]`)
    expect(row.attributes('data-tool-kind')).toBe('mcp')
    expect(row.find('[data-testid="tool-picker-mcp-badge"]').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect((textarea.element as HTMLTextAreaElement).value).toBe(`/tool-${MCP_NAME}`)
  })

  it('a compiled-in row carries no MCP badge', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, '/tool-read')

    const row = wrapper.find('[data-tool-name="read_file"]')
    expect(row.attributes('data-tool-kind')).toBe('builtin')
    expect(row.find('[data-testid="tool-picker-mcp-badge"]').exists()).toBe(false)
  })

  it("asks the backend for the active workspace's MCP tools", async () => {
    const WORKSPACE = 'ws_with_servers'
    seedWorkspace(WORKSPACE)
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, '/tool-')

    expect(getRegistryMock).toHaveBeenCalledWith({
      includeMcp: true,
      workspaceId: WORKSPACE,
    })
  })
})

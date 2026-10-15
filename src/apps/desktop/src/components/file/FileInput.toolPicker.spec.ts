/**
 * FileInput `/tool-` picker — trigger, fetch-once, filter, insert, error.
 *
 * Contract under test:
 *   - Typing `/tool-` opens the picker and calls
 *     `api.getAgentToolsRegistry()` ONCE per mount (client-side substring
 *     filter after that — no refetch while typing past the dash).
 *   - Enter inserts the canonical `/tool-<name>` token, Esc closes
 *     without inserting.
 *   - A registry rejection renders the error block, never an empty list.
 *   - The trigger is the literal `/tool-` prefix at message start or
 *     after whitespace. A bare `/`, a path like `/home/ginwa/pabrik`,
 *     `http://` and `a/b` never open it.
 *   - Unlike `/skill-`, the registry is NOT workspace-scoped, so the
 *     picker opens with no active workspace too.
 *
 * And the `/tool-` completion hint that precedes it:
 *   - A proper prefix of the command (`/t`, `/to`, `/too`, `/tool`)
 *     renders ONE suggestion row reading `/tool-`.
 *   - Enter or Tab rewrites the token to `/tool-` and the picker opens.
 *   - The hint never fetches the registry and never renders the list.
 *
 * Mirrors `FileInput.skillPicker.spec.ts` one-for-one; the differences
 * are the marker, the data source and the absence of a workspace gate.
 */
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

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

function toolsPayload() {
  return {
    tools: [
      { name: 'read_file', description: 'reads a file' },
      { name: 'write_file', description: 'writes a file' },
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

/**  * Set the textarea value, park the cursor at the end, dispatch `input` so `autoResize` updates
 * `cursorPos`, then wait out the 150ms detect debounce plus promise flushes. */
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

describe('FileInput — /tool picker', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    getSkillsMock.mockReset()
    searchFilesMock.mockReset()
    getRegistryMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
    getSkillsMock.mockResolvedValue({ skills: [] })
    getRegistryMock.mockResolvedValue(toolsPayload())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("typing '/tool-' opens the picker and calls getAgentToolsRegistry once", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-')

    expect(getRegistryMock).toHaveBeenCalledTimes(1)
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="tool-picker-list"]').text()).toContain('read_file')
  })

  it('typing past the dash filters client-side without refetching', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-')

    expect(getRegistryMock).toHaveBeenCalledTimes(1)

    await typeInTextarea(textarea, '/tool-write')
    expect(getRegistryMock).toHaveBeenCalledTimes(1)
    const list = wrapper.find('[data-testid="tool-picker-list"]')
    expect(list.text()).toContain('write_file')
    expect(list.text()).not.toContain('read_file')
  })

  it("Enter inserts '/tool-<name>' as plain text", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-write')
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/tool-write_file')
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
  })

  it('Esc closes the picker without inserting', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-')
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()

    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/tool-')
  })

  it('getAgentToolsRegistry rejection renders the error block, never an empty list', async () => {
    seedWorkspace()
    getRegistryMock.mockRejectedValue(new Error('backend down'))
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-')

    const error = wrapper.find('[data-testid="tool-picker-error"]')
    expect(error.exists()).toBe(true)
    expect(error.text()).toContain('backend down')
    expect(wrapper.find('[data-testid="tool-picker-list"]').text()).not.toContain('No tools found')
  })

  it('the registry is not workspace-scoped: no workspace still opens the picker', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/tool-')

    expect(getRegistryMock).toHaveBeenCalledTimes(1)
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)
  })

  it('a slash inside a URL or path never opens the picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, 'see http://example.com/x')
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)

    await typeInTextarea(textarea, 'see a/b')
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    expect(getRegistryMock).not.toHaveBeenCalled()
  })

  describe('the picker only opens on the literal /tool- prefix', () => {
    it('a bare `/` does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })

    it('a partial `/to` prefix does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })

    it('`/tool` without the dash does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/tool')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })

    it('a filesystem path does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'check the source code /home/ginwa/pabrik')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })

    it('prose that merely contains a slash does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'to see the features pabrik ai check the source code')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })

    it('a `/tool-` token after whitespace does open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'please run /tool-')

      expect(getRegistryMock).toHaveBeenCalledTimes(1)
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)
    })

    it('a `/tool-` token mid-word does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'a/tool-read')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    })
  })

  describe('complex tool names (underscores, case)', () => {
    function complexToolsPayload() {
      return {
        tools: [
          { name: 'spawn_sub_agent', description: 'spawns a sub-agent' },
          { name: 'read_file', description: 'reads a file from disk' },
          { name: 'write_file', description: 'writes a file to disk' },
        ],
      }
    }

    it('underscore-heavy query narrows: /tool-spawn', async () => {
      seedWorkspace()
      getRegistryMock.mockResolvedValue(complexToolsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/tool-spawn')

      const list = wrapper.find('[data-testid="tool-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('spawn_sub_agent')
      expect(list.text()).not.toContain('read_file')
      expect(list.text()).not.toContain('write_file')
    })

    it('a failing query keeps the picker open with No tools found', async () => {
      seedWorkspace()
      getRegistryMock.mockResolvedValue(complexToolsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/tool-zzz-nope')

      const list = wrapper.find('[data-testid="tool-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('No tools found')
    })

    it('matching is case-insensitive: /TOOL-READ', async () => {
      seedWorkspace()
      getRegistryMock.mockResolvedValue(complexToolsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/TOOL-READ')

      const list = wrapper.find('[data-testid="tool-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('read_file')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/tool-read_file')
    })

    it('Enter replaces the whole typed span, keeping the prose before it', async () => {
      seedWorkspace()
      getRegistryMock.mockResolvedValue(complexToolsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'run /tool-read')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('run /tool-read_file')
    })

    it('text typed after the token closes the picker, so Enter sends', async () => {
      seedWorkspace()
      getRegistryMock.mockResolvedValue(complexToolsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'run /tool-read now')

      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('')
    })
  })

  // The discoverability step that precedes the picker: the user has typed enough to be heading for
  // the tool command but not the dash yet, so the composer offers the one completion that exists.

  // These specs pin the hint as its OWN surface (`tool-command-suggestion`) rather than reusing
  // `tool-picker-list`, so the "a partial `/to` does not open the picker" specs above keep meaning
  // what they say.
  describe('the /tool- completion hint', () => {
    const HINT = '[data-testid="tool-command-suggestion"]'
    const PICKER = '[data-testid="tool-picker-list"]'

    it("typing '/to' shows exactly one suggestion reading /tool-", async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      const hint = wrapper.find(HINT)
      expect(hint.exists()).toBe(true)
      expect(hint.text()).toContain('/tool-')
      // One row, not a list of candidates.
      expect(hint.findAll('button')).toHaveLength(1)
    })

    it('the hint does not fetch the registry and does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      expect(getRegistryMock).not.toHaveBeenCalled()
      expect(wrapper.find(PICKER).exists()).toBe(false)
    })

    it('every proper prefix of the command shows the hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      const seen: Record<string, { hint: boolean; picker: boolean }> = {}
      for (const prefix of ['/t', '/to', '/too', '/tool']) {
        await typeInTextarea(textarea, prefix)
        seen[prefix] = {
          hint: wrapper.find(HINT).exists(),
          picker: wrapper.find(PICKER).exists(),
        }
      }
      expect(seen).toEqual({
        '/t': { hint: true, picker: false },
        '/to': { hint: true, picker: false },
        '/too': { hint: true, picker: false },
        '/tool': { hint: true, picker: false },
      })
    })

    it('the hint is case-insensitive: /TO', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/TO')

      expect(wrapper.find(HINT).exists()).toBe(true)
    })

    it('Enter completes the token to /tool- and opens the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/tool-')
      expect(wrapper.find(HINT).exists()).toBe(false)
      expect(wrapper.find(PICKER).exists()).toBe(true)
      expect(getRegistryMock).toHaveBeenCalledTimes(1)
      expect(wrapper.find(PICKER).text()).toContain('read_file')
    })

    it('Tab also completes the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      await textarea.trigger('keydown', { key: 'Tab' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/tool-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })

    it('clicking the suggestion row completes the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      await wrapper.find('[data-testid="tool-command-suggestion-row"]').trigger('click')
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/tool-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })

    it('Esc dismisses the hint without touching the text', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')
      expect(wrapper.find(HINT).exists()).toBe(true)

      await textarea.trigger('keydown', { key: 'Escape' })
      await flushPromises()

      expect(wrapper.find(HINT).exists()).toBe(false)
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/to')
      expect(getRegistryMock).not.toHaveBeenCalled()
    })

    it('Enter on the hint does not send the message', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      expect(wrapper.emitted('submit')).toBeUndefined()
    })

    it('the hint keeps the prose before the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'please run /to')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('please run /tool-')
    })

    it('after completing, typing the tool name filters the list', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      await typeInTextarea(textarea, '/tool-write')
      const list = wrapper.find(PICKER)
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('write_file')
      expect(list.text()).not.toContain('read_file')
      // Still one fetch — the completion did not restart the load.
      expect(getRegistryMock).toHaveBeenCalledTimes(1)
    })

    it('a bare `/` shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/')

      expect(wrapper.find(HINT).exists()).toBe(false)
      expect(getRegistryMock).not.toHaveBeenCalled()
    })

    it('a path or URL shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, 'see http://example.com/x')
      expect(wrapper.find(HINT).exists()).toBe(false)

      await typeInTextarea(textarea, 'check /home/ginwa/pabrik')
      expect(wrapper.find(HINT).exists()).toBe(false)
      expect(getRegistryMock).not.toHaveBeenCalled()
    })

    it('a prefix mid-word shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'a/to')

      expect(wrapper.find(HINT).exists()).toBe(false)
    })

    it('the hint works with no workspace scope (it is a static string)', async () => {
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/to')

      expect(wrapper.find(HINT).exists()).toBe(true)
      expect(getRegistryMock).not.toHaveBeenCalled()

      // Completing still rewrites the text; the picker opens too, because
      // the registry is not workspace-scoped.
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/tool-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })
  })

  // The two slash commands share one composer. Typing one must not leave
  // the other's surface open, and the `/skill-` specs must keep meaning
  // what they say when a `/tool-` token is in the same message.
  describe('the two slash pickers do not collide', () => {
    it('typing /tool- closes an open /skill- picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, '/skill-')
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)

      await typeInTextarea(textarea, '/tool-')
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)
    })

    it('typing /skill- closes an open /tool- picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, '/tool-')
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(true)

      await typeInTextarea(textarea, '/skill-')
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)
    })

    it('the /tool- hint and the /skill- hint never render at once', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, '/to')
      expect(wrapper.find('[data-testid="tool-command-suggestion"]').exists()).toBe(true)
      expect(wrapper.find('[data-testid="skill-command-suggestion"]').exists()).toBe(false)

      await typeInTextarea(textarea, '/sk')
      expect(wrapper.find('[data-testid="tool-command-suggestion"]').exists()).toBe(false)
      expect(wrapper.find('[data-testid="skill-command-suggestion"]').exists()).toBe(true)
    })

    it('a /skill- token later in the message leaves the /tool- picker shut', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, 'use /tool-read_file then /skill-')
      expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)
    })
  })
})

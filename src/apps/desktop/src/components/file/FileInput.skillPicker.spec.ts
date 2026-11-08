/** FileInput `/skill-` picker — trigger, fetch-once, filter, insert, error. */
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
}))

const getSkillsMock = api.getSkills as unknown as ReturnType<typeof vi.fn>
const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

const WS_ID = 'ws_1'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

function skillsPayload() {
  return {
    skills: [
      { name: 'review', description: 'reviews code' },
      { name: 'deploy', description: 'deploys the app' },
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

describe('FileInput — /skill picker', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    getSkillsMock.mockReset()
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
    getSkillsMock.mockResolvedValue(skillsPayload())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("typing '/skill-' opens the picker and calls getSkills once", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-')

    expect(getSkillsMock).toHaveBeenCalledTimes(1)
    expect(getSkillsMock).toHaveBeenCalledWith(WS_ID)
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-picker-list"]').text()).toContain('review')
  })

  it('typing past the dash filters client-side without refetching', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-')

    expect(getSkillsMock).toHaveBeenCalledTimes(1)

    await typeInTextarea(textarea, '/skill-dep')
    expect(getSkillsMock).toHaveBeenCalledTimes(1)
    const list = wrapper.find('[data-testid="skill-picker-list"]')
    expect(list.text()).toContain('deploy')
    expect(list.text()).not.toContain('review')
  })

  it("Enter inserts '/skill-<name>' as plain text", async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-dep')
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/skill-deploy')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
  })

  it('Esc closes the picker without inserting', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('/skill-')
  })

  it('getSkills rejection renders the error block, never an empty list', async () => {
    seedWorkspace()
    getSkillsMock.mockRejectedValue(new Error('backend down'))
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-')

    const error = wrapper.find('[data-testid="skill-picker-error"]')
    expect(error.exists()).toBe(true)
    expect(error.text()).toContain('backend down')
    expect(wrapper.find('[data-testid="skill-picker-list"]').text()).not.toContain(
      'No skills found',
    )
  })

  it('no workspace -> `/skill-` does not open and getSkills is not called', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/skill-')

    expect(getSkillsMock).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
  })

  it('a slash inside a URL or path never opens the picker', async () => {
    seedWorkspace()
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')

    await typeInTextarea(textarea, 'see http://example.com/x')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)

    await typeInTextarea(textarea, 'see a/b')
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    expect(getSkillsMock).not.toHaveBeenCalled()
  })

  describe('the picker only opens on the literal /skill- prefix', () => {
    it('a bare `/` does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })

    it('a partial `/sk` prefix does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })

    it('`/skill` without the dash does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/skill')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })

    it('a filesystem path does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'check the source code /home/ginwa/pabrik')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })

    it('prose that merely contains a slash does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'to see the features pabrik ai check the source code')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })

    it('a `/skill-` token after whitespace does open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'please run /skill-')

      expect(getSkillsMock).toHaveBeenCalledTimes(1)
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(true)
    })

    it('a `/skill-` token mid-word does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'a/skill-dep')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    })
  })

  describe('complex skill names (dashes, dots, case)', () => {
    function complexSkillsPayload() {
      return {
        skills: [
          {
            name: 'before-after-screenshots-from-two-checkouts',
            description: 'before/after screenshots for PR review',
          },
          { name: 'zig-0.16-trap', description: 'zig version trap' },
          { name: 'deploy-prod', description: 'deploys the app to production' },
        ],
      }
    }

    it('dash-heavy query narrows: /skill-before-after', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/skill-before-after')

      const list = wrapper.find('[data-testid="skill-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('before-after-screenshots-from-two-checkouts')
      expect(list.text()).not.toContain('zig-0.16-trap')
      expect(list.text()).not.toContain('deploy-prod')
    })

    it('dots in the query work: /skill-0.16', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/skill-0.16')

      const list = wrapper.find('[data-testid="skill-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('zig-0.16-trap')
      expect(list.text()).not.toContain('deploy-prod')
    })

    it('a failing query keeps the picker open with No skills found', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/skill-zzz-nope')

      const list = wrapper.find('[data-testid="skill-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('No skills found')
    })

    it('matching is case-insensitive: /SKILL-DEPLOY', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/SKILL-DEPLOY')

      const list = wrapper.find('[data-testid="skill-picker-list"]')
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('deploy-prod')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-deploy-prod')
    })

    it('Enter replaces the whole typed span, keeping the prose before it', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'run /skill-dep')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('run /skill-deploy-prod')
    })

    it('text typed after the token closes the picker, so Enter sends', async () => {
      seedWorkspace()
      getSkillsMock.mockResolvedValue(complexSkillsPayload())
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'run /skill-dep now')

      expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('')
    })
  })

  describe('the slash command menu', () => {
    const MENU = '[data-testid="slash-command-menu"]'
    const PICKER = '[data-testid="skill-picker-list"]'

    it("typing '/sk' narrows the menu to the one skill command", async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      const menu = wrapper.find(MENU)
      expect(menu.exists()).toBe(true)
      expect(menu.findAll('button')).toHaveLength(1)
      expect(menu.text()).toContain('/skill-')
    })

    it('the menu does not fetch skills and does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find(PICKER).exists()).toBe(false)
    })

    it('every proper prefix of the command keeps the menu on the skill row', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      const seen: Record<string, { menu: boolean; rows: number; picker: boolean }> = {}
      for (const prefix of ['/s', '/sk', '/ski', '/skil', '/skill']) {
        await typeInTextarea(textarea, prefix)
        seen[prefix] = {
          menu: wrapper.find(MENU).exists(),
          rows: wrapper.find(MENU).findAll('button').length,
          picker: wrapper.find(PICKER).exists(),
        }
      }
      expect(seen).toEqual({
        '/s': { menu: true, rows: 1, picker: false },
        '/sk': { menu: true, rows: 1, picker: false },
        '/ski': { menu: true, rows: 1, picker: false },
        '/skil': { menu: true, rows: 1, picker: false },
        '/skill': { menu: true, rows: 1, picker: false },
      })
    })

    it('the menu is case-insensitive: /SK', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/SK')

      expect(wrapper.find(MENU).exists()).toBe(true)
      expect(wrapper.find(MENU).text()).toContain('/skill-')
    })

    it('Enter completes the token to /skill- and opens the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(MENU).exists()).toBe(false)
      expect(wrapper.find(PICKER).exists()).toBe(true)
      expect(getSkillsMock).toHaveBeenCalledTimes(1)
      expect(wrapper.find(PICKER).text()).toContain('review')
    })

    it('Tab also completes the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await textarea.trigger('keydown', { key: 'Tab' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })

    it('clicking the skill row completes the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await wrapper.find('[data-testid="slash-command-skill-"]').trigger('click')
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })

    it('Esc dismisses the menu without touching the text', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')
      expect(wrapper.find(MENU).exists()).toBe(true)

      await textarea.trigger('keydown', { key: 'Escape' })
      await flushPromises()

      expect(wrapper.find(MENU).exists()).toBe(false)
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/sk')
      expect(getSkillsMock).not.toHaveBeenCalled()
    })

    it('Enter on the menu does not send the message', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      expect(wrapper.emitted('submit')).toBeUndefined()
    })

    it('the menu keeps the prose before the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'please run /sk')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('please run /skill-')
    })

    it('after completing, typing the skill name filters the list', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      await typeInTextarea(textarea, '/skill-dep')
      const list = wrapper.find(PICKER)
      expect(list.exists()).toBe(true)
      expect(list.text()).toContain('deploy')
      expect(list.text()).not.toContain('review')
      expect(getSkillsMock).toHaveBeenCalledTimes(1)
    })

    it('a path or URL does not open the menu', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, 'see http://example.com/x')
      expect(wrapper.find(MENU).exists()).toBe(false)

      await typeInTextarea(textarea, 'check /home/ginwa/pabrik')
      expect(wrapper.find(MENU).exists()).toBe(false)
      expect(getSkillsMock).not.toHaveBeenCalled()
    })

    it('a prefix mid-word does not open the menu', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'a/sk')

      expect(wrapper.find(MENU).exists()).toBe(false)
    })

    it('completing works with no workspace scope; only the picker stays shut', async () => {
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      expect(wrapper.find(MENU).exists()).toBe(true)
      expect(getSkillsMock).not.toHaveBeenCalled()

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(PICKER).exists()).toBe(false)
    })
  })
})

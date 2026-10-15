/**
 * FileInput `/skill-` picker — trigger, fetch-once, filter, insert, error.
 *
 * Contract under test:
 *   - Typing `/skill-` opens the picker and calls `api.getSkills(ws)` ONCE
 *     per workspace per mount (client-side substring filter after that —
 *     no refetch while typing past the dash).
 *   - Enter inserts the canonical `/skill-<name>` token, Esc closes
 *     without inserting.
 *   - A `getSkills` rejection renders the error block, never an empty list.
 *   - With no workspace scope (or no pinia) `/skill-` does not open.
 *   - The trigger is the literal `/skill-` prefix at message start or
 *     after whitespace. A bare `/`, a path like `/home/ginwa/pabrik`,
 *     `http://` and `a/b` never open it.
 *
 * And the `/skill-` completion hint that precedes it:
 *   - A proper prefix of the command (`/s`, `/sk`, `/ski`, `/skil`,
 *     `/skill`) renders ONE suggestion row reading `/skill-`.
 *   - Enter or Tab rewrites the token to `/skill-` and the picker opens.
 *   - The hint never fetches skills and never renders the picker list.
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

  // The discoverability step that precedes the picker: the user has typed enough to be heading for
  // the skill command but not the dash yet, so the composer offers the one completion that exists.

  // These specs pin the hint as its OWN surface (`skill-command-suggestion`) rather than reusing
  // `skill-picker-list`, so the "a partial `/sk` does not open the picker" specs above keep meaning
  // what they say.
  describe('the /skill- completion hint', () => {
    const HINT = '[data-testid="skill-command-suggestion"]'
    const PICKER = '[data-testid="skill-picker-list"]'

    it("typing '/sk' shows exactly one suggestion reading /skill-", async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      const hint = wrapper.find(HINT)
      expect(hint.exists()).toBe(true)
      expect(hint.text()).toContain('/skill-')
      // One row, not a list of candidates.
      expect(hint.findAll('button')).toHaveLength(1)
    })

    it('the hint does not fetch skills and does not open the picker', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      expect(getSkillsMock).not.toHaveBeenCalled()
      expect(wrapper.find(PICKER).exists()).toBe(false)
    })

    it('every proper prefix of the command shows the hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      const seen: Record<string, { hint: boolean; picker: boolean }> = {}
      for (const prefix of ['/s', '/sk', '/ski', '/skil', '/skill']) {
        await typeInTextarea(textarea, prefix)
        seen[prefix] = {
          hint: wrapper.find(HINT).exists(),
          picker: wrapper.find(PICKER).exists(),
        }
      }
      expect(seen).toEqual({
        '/s': { hint: true, picker: false },
        '/sk': { hint: true, picker: false },
        '/ski': { hint: true, picker: false },
        '/skil': { hint: true, picker: false },
        '/skill': { hint: true, picker: false },
      })
    })

    it('the hint is case-insensitive: /SK', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/SK')

      expect(wrapper.find(HINT).exists()).toBe(true)
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
      expect(wrapper.find(HINT).exists()).toBe(false)
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

    it('clicking the suggestion row completes the token', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await wrapper.find('[data-testid="skill-command-suggestion-row"]').trigger('click')
      await flushPromises()

      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(PICKER).exists()).toBe(true)
    })

    it('Esc dismisses the hint without touching the text', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')
      expect(wrapper.find(HINT).exists()).toBe(true)

      await textarea.trigger('keydown', { key: 'Escape' })
      await flushPromises()

      expect(wrapper.find(HINT).exists()).toBe(false)
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/sk')
      expect(getSkillsMock).not.toHaveBeenCalled()
    })

    it('Enter on the hint does not send the message', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()

      expect(wrapper.emitted('submit')).toBeUndefined()
    })

    it('the hint keeps the prose before the token', async () => {
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
      // Still one fetch — the completion did not restart the load.
      expect(getSkillsMock).toHaveBeenCalledTimes(1)
    })

    it('a bare `/` shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/')

      expect(wrapper.find(HINT).exists()).toBe(false)
      expect(getSkillsMock).not.toHaveBeenCalled()
    })

    it('a path or URL shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')

      await typeInTextarea(textarea, 'see http://example.com/x')
      expect(wrapper.find(HINT).exists()).toBe(false)

      await typeInTextarea(textarea, 'check /home/ginwa/pabrik')
      expect(wrapper.find(HINT).exists()).toBe(false)
      expect(getSkillsMock).not.toHaveBeenCalled()
    })

    it('a prefix mid-word shows no hint', async () => {
      seedWorkspace()
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, 'a/sk')

      expect(wrapper.find(HINT).exists()).toBe(false)
    })

    it('the hint works with no workspace scope (it is a static string)', async () => {
      const wrapper = await mountInput()
      const textarea = wrapper.find('textarea')
      await typeInTextarea(textarea, '/sk')

      expect(wrapper.find(HINT).exists()).toBe(true)
      expect(getSkillsMock).not.toHaveBeenCalled()

      // Completing still rewrites the text; only the picker stays shut.
      await textarea.trigger('keydown', { key: 'Enter' })
      await flushPromises()
      const element = textarea.element as HTMLTextAreaElement
      expect(element.value).toBe('/skill-')
      expect(wrapper.find(PICKER).exists()).toBe(false)
    })
  })
})

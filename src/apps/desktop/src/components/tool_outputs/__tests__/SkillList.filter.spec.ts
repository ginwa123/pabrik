/** SkillList.vue — search, facets, sort, count and keyboard navigation. The
 * API is mocked at the boundary; the assertions read the rendered rows. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import SkillList from '../SkillList.vue'
import { useWorkspacesStore, type Workspace } from '../../../stores/workspaces'
import type { Skill } from '../../../api'

const { getSkillsMock } = vi.hoisted(() => ({
  getSkillsMock: vi.fn(),
}))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return {
    ...actual,
    getSkills: getSkillsMock,
  }
})

const WS_ID = 'ws_1'

const ROWS: Skill[] = [
  {
    name: 'behavior-unit-tests',
    description: 'Write deterministic unit tests',
    is_can_auto_improve: false,
  },
  {
    name: 'zig-build-test-sharding',
    description: 'Split a slow zig build test',
    is_can_auto_improve: true,
  },
  {
    name: 'verify-html-wireframe',
    description: 'Assert DOM geometry in a browser',
    is_can_auto_improve: true,
  },
]

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: '📁', items: [], expanded: true } satisfies Workspace,
  ]
}

/** The names of the rows currently rendered, in order. */
function renderedNames(wrapper: ReturnType<typeof mount>): string[] {
  return wrapper.findAll('[data-skill-name]').map((el) => el.attributes('data-skill-name') ?? '')
}

async function mountList(): Promise<ReturnType<typeof mount>> {
  const wrapper = mount(SkillList, {
    props: { selectedSkillName: null, workspaceId: WS_ID },
  })
  await flushPromises()
  return wrapper
}

beforeEach(() => {
  setActivePinia(createPinia())
  getSkillsMock.mockReset()
  getSkillsMock.mockResolvedValue({ skills: ROWS })
})

describe('SkillList — searching', () => {
  it('renders every skill when nothing is typed', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    expect(renderedNames(wrapper)).toEqual([
      'behavior-unit-tests',
      'zig-build-test-sharding',
      'verify-html-wireframe',
    ])
  })

  it('narrows to the rows whose name or description matches', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('zig')
    await flushPromises()

    expect(renderedNames(wrapper)).toEqual(['zig-build-test-sharding'])
  })

  it('matches the description, not only the name', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('geometry')
    await flushPromises()

    expect(renderedNames(wrapper)).toEqual(['verify-html-wireframe'])
  })

  it('counts the rows the query leaves, out of the loaded total', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('zig')
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-count"]').text()).toBe('1 of 3')
  })

  it('offers a way out when the query matches nothing', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('kubernetes')
    await flushPromises()

    // A distinct state from "this workspace has no skills": the workspace
    // HAS skills, the search found none, and only this one can be cleared.
    expect(wrapper.find('[data-testid="skill-list-no-match"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-list-empty"]').exists()).toBe(false)

    await wrapper.find('[data-testid="skill-list-no-match-clear"]').trigger('click')
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(3)
  })

  it('clears the query on Escape', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const input = wrapper.find('[data-testid="skill-search-input"]')
    await input.setValue('zig')
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(1)

    await input.trigger('keydown', { key: 'Escape' })
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(3)
  })

  it('clears the query with the ✕ button', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('zig')
    await flushPromises()

    await wrapper.find('[data-testid="skill-search-clear"]').trigger('click')
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(3)
  })
})

describe('SkillList — facets', () => {
  it('narrows to the editable rows', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-facet-auto-improve"]').trigger('click')
    await flushPromises()

    expect(renderedNames(wrapper)).toEqual(['zig-build-test-sharding', 'verify-html-wireframe'])
  })

  it('narrows to the human-pinned rows', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-facet-pinned"]').trigger('click')
    await flushPromises()

    expect(renderedNames(wrapper)).toEqual(['behavior-unit-tests'])
  })

  it('shows both groups when both chips are on', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-facet-auto-improve"]').trigger('click')
    await wrapper.find('[data-testid="skill-facet-pinned"]').trigger('click')
    await flushPromises()

    expect(renderedNames(wrapper).length).toBe(3)
  })

  it('turns a chip back off on a second click', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const chip = wrapper.find('[data-testid="skill-facet-pinned"]')
    await chip.trigger('click')
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(1)

    await chip.trigger('click')
    await flushPromises()
    expect(renderedNames(wrapper).length).toBe(3)
  })

  it('ANDs the query with the facet', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('zig')
    await wrapper.find('[data-testid="skill-facet-pinned"]').trigger('click')
    await flushPromises()

    // "zig" is editable, "pinned" is not — nothing satisfies both.
    expect(wrapper.find('[data-testid="skill-list-no-match"]').exists()).toBe(true)
  })
})

describe('SkillList — sorting', () => {
  it('puts the editable rows first when asked', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-sort-select"]').setValue('auto_improve')
    await flushPromises()

    // Editable rows first, then alphabetical among them — "verify"
    // precedes "zig", and the pinned row sinks to the bottom.
    expect(renderedNames(wrapper)).toEqual([
      'verify-html-wireframe',
      'zig-build-test-sharding',
      'behavior-unit-tests',
    ])
  })

  it('keeps name order by default', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    expect(renderedNames(wrapper)).toEqual([
      'behavior-unit-tests',
      'zig-build-test-sharding',
      'verify-html-wireframe',
    ])
  })
})

describe('SkillList — clearing everything', () => {
  it('resets query, facets and sort in one click', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-testid="skill-search-input"]').setValue('zig')
    await wrapper.find('[data-testid="skill-facet-pinned"]').trigger('click')
    await wrapper.find('[data-testid="skill-sort-select"]').setValue('auto_improve')
    await flushPromises()

    await wrapper.find('[data-testid="skill-clear-filters"]').trigger('click')
    await flushPromises()

    expect(renderedNames(wrapper).length).toBe(3)
    expect(
      (wrapper.find('[data-testid="skill-search-input"]').element as HTMLInputElement).value,
    ).toBe('')
    // The button disappears once there is nothing to clear.
    expect(wrapper.find('[data-testid="skill-clear-filters"]').exists()).toBe(false)
  })
})

describe('SkillList — keyboard navigation', () => {
  it('moves a cursor with the arrow keys and opens the row on Enter', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const list = wrapper.find('[data-testid="skill-list"]')

    await list.trigger('keydown', { key: 'ArrowDown' })
    await flushPromises()
    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'behavior-unit-tests',
    )

    await list.trigger('keydown', { key: 'ArrowDown' })
    await flushPromises()
    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'zig-build-test-sharding',
    )

    await list.trigger('keydown', { key: 'Enter' })
    await flushPromises()
    expect(wrapper.emitted('selectSkill')).toEqual([['zig-build-test-sharding']])
  })

  it('clamps at the last row instead of wrapping to the top', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const list = wrapper.find('[data-testid="skill-list"]')

    for (let i = 0; i < 6; i++) {
      await list.trigger('keydown', { key: 'ArrowDown' })
    }
    await flushPromises()

    // Three rows: the cursor stops on the third, it does not wrap.
    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'verify-html-wireframe',
    )
  })

  it('moves back up with ArrowUp', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const list = wrapper.find('[data-testid="skill-list"]')

    await list.trigger('keydown', { key: 'ArrowDown' })
    await list.trigger('keydown', { key: 'ArrowDown' })
    await list.trigger('keydown', { key: 'ArrowUp' })
    await flushPromises()

    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'behavior-unit-tests',
    )
  })

  it('jumps to the first and last row with Home and End', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    const list = wrapper.find('[data-testid="skill-list"]')

    await list.trigger('keydown', { key: 'End' })
    await flushPromises()
    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'verify-html-wireframe',
    )

    await list.trigger('keydown', { key: 'Home' })
    await flushPromises()
    expect(wrapper.find('[data-cursor="true"]').attributes('data-skill-name')).toBe(
      'behavior-unit-tests',
    )
  })

  it('opens the row on a plain click, as before', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-skill-name="verify-html-wireframe"]').trigger('click')
    await flushPromises()

    expect(wrapper.emitted('selectSkill')).toEqual([['verify-html-wireframe']])
  })
})

describe('SkillList — the auto-improve flag', () => {
  it('is not repeated on every row', async () => {
    seedWorkspace()
    const wrapper = await mountList()

    // It used to be one checkbox per row — three here, 41 on a real
    // workspace — each a PATCH on click.
    expect(wrapper.findAll('[data-testid="skill-auto-improve-toggle"]').length).toBe(0)
  })

  it('appears on the row the pointer is on', async () => {
    seedWorkspace()
    const wrapper = await mountList()
    await wrapper.find('[data-skill-name="zig-build-test-sharding"]').trigger('mouseenter')
    await flushPromises()

    const toggles = wrapper.findAll('[data-testid="skill-auto-improve-toggle"]')
    expect(toggles.length).toBe(1)
  })
})

describe('SkillList — the states that must not be confused', () => {
  it('shows the empty state when the workspace has no skills', async () => {
    seedWorkspace()
    getSkillsMock.mockResolvedValue({ skills: [] })
    const wrapper = await mountList()

    expect(wrapper.find('[data-testid="skill-list-empty"]').exists()).toBe(true)
    // No search box over an empty list: there is nothing to narrow.
    expect(wrapper.find('[data-testid="skill-search-input"]').exists()).toBe(false)
  })

  it('shows the error state, not the empty state, when the read fails', async () => {
    seedWorkspace()
    getSkillsMock.mockRejectedValue(new Error('HTTP 500 DB error'))
    const wrapper = mount(SkillList, {
      props: { selectedSkillName: null, workspaceId: WS_ID },
    })
    await flushPromises()
    await flushPromises()

    expect(wrapper.find('[data-testid="skill-list-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="skill-list-empty"]').exists()).toBe(false)
  })
})

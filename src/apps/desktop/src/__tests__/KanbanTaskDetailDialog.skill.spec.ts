/** Skills picker in KanbanTaskDetailDialog (create mode only). Migration 112:
 * a checkbox dropdown that stays open, a search box, and removable chips.
 * Mount pattern: same as KanbanTaskDetailDialog.profile.spec.ts. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import * as api from '@/api'
import type { Task } from '@/stores/workspaces'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

const SKILLS = [
  { name: 'pdf', description: 'Work with PDFs', is_can_auto_improve: true },
  { name: 'zig-trap', description: 'A Zig trap', is_can_auto_improve: true },
  {
    name: 'behavior-unit-tests',
    description: 'Write deterministic unit tests',
    is_can_auto_improve: true,
  },
]

const PICKER = '[data-testid="kanban-task-detail-skill-picker"]'
const DROPDOWN = '[data-testid="kanban-task-detail-skill-picker-dropdown"]'
const ROW = '[data-testid="kanban-task-detail-skill-picker-item"]'
const CHECK = '[data-testid="kanban-task-detail-skill-picker-check"]'
const SEARCH = '[data-testid="kanban-task-detail-skill-picker-search"]'
const CLEAR = '[data-testid="kanban-task-detail-skill-picker-clear"]'
const COUNT = '[data-testid="kanban-task-detail-skill-picker-count"]'
const CHIPS = '[data-testid="kanban-task-detail-skill-chips"]'

describe('KanbanTaskDetailDialog — skills picker (Migration 112)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.spyOn(api, 'getSkills').mockResolvedValue({ skills: SKILLS })
    // The profile picker loads on the same open path — keep it quiet.
    vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue({ profiles: {} })
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/home/ginwa',
      absolute: '/home/ginwa',
      home: '/home/ginwa',
      entries: [],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
    vi.restoreAllMocks()
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        task: null,
        mode: 'create',
        workspaceId: 'ws_1',
        ...propsOverride,
      },
    })
    return wrapper
  }

  async function typeInto(selector: string, value: string) {
    const input = findInDom<HTMLInputElement>(selector)
    if (!input) throw new Error(`input missing: ${selector}`)
    input.value = value
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
  }

  async function openPicker() {
    findInDom<HTMLButtonElement>(PICKER)?.click()
    await flushPromises()
  }

  async function clickRow(index: number) {
    findAllInDom<HTMLButtonElement>(ROW)[index]?.click()
    await flushPromises()
  }

  function labels(): string[] {
    return findAllInDom<HTMLButtonElement>(ROW).map((row) => row.textContent ?? '')
  }

  function checkedCount(): number {
    return findAllInDom<HTMLInputElement>(CHECK).filter((box) => box.checked).length
  }

  function chips(): string[] {
    const strip = findInDom(CHIPS)
    if (!strip) return []
    return Array.from(strip.children).map((child) => child.textContent?.trim() ?? '')
  }

  function pickerText(): string {
    return findInDom(PICKER)?.textContent ?? ''
  }

  it('renders the skills picker in create mode and not in edit mode', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom(PICKER)).not.toBeNull()

    wrapper?.unmount()
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(findInDom(PICKER)).toBeNull()
  })

  it('starts at "None" with no chips and no count badge', async () => {
    mountDialog()
    await flushPromises()
    expect(pickerText()).toContain('None')
    expect(chips()).toHaveLength(0)
    expect(findInDom(COUNT)).toBeNull()
  })

  it('picking a row checks it and leaves the dropdown open', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()

    await clickRow(0)

    expect(findInDom(DROPDOWN)).not.toBeNull()
    expect(checkedCount()).toBe(1)
    expect(pickerText()).toContain('pdf')
  })

  it('picking a second row counts it: label, badge and one chip per pick', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()

    await clickRow(0)
    await clickRow(1)

    expect(checkedCount()).toBe(2)
    expect(findInDom(COUNT)?.textContent).toBe('2')
    expect(pickerText()).toContain('pdf +1')
    expect(chips()).toHaveLength(2)
    expect(chips()[0]).toContain('pdf')
    expect(chips()[1]).toContain('zig-trap')
  })

  it('clicking a checked row again drops that skill', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    await clickRow(0)
    await clickRow(1)

    await clickRow(0)

    expect(checkedCount()).toBe(1)
    expect(pickerText()).toContain('zig-trap')
    expect(chips()).toHaveLength(1)
  })

  it('a chip remove button drops exactly that skill', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    await clickRow(0)
    await clickRow(1)
    await openPicker() // close: the chips are used with the dropdown shut

    findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-skill-chip-remove-pdf"]',
    )?.click()
    await flushPromises()

    expect(chips()).toHaveLength(1)
    expect(chips()[0]).toContain('zig-trap')
    expect(pickerText()).toContain('zig-trap')
  })

  it('"Clear all" empties the selection, the chips and every checkbox', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    await clickRow(0)
    await clickRow(1)

    findInDom<HTMLButtonElement>(CLEAR)?.click()
    await flushPromises()

    expect(checkedCount()).toBe(0)
    expect(chips()).toHaveLength(0)
    expect(pickerText()).toContain('None')
    expect(findInDom(COUNT)).toBeNull()
  })

  it('the search box narrows the rows by name, case-insensitively', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    expect(labels()).toHaveLength(3)

    await typeInto(SEARCH, 'ZIG')

    expect(labels()).toHaveLength(1)
    expect(labels()[0]).toContain('zig-trap')
  })

  it('the search box also matches the description', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()

    await typeInto(SEARCH, 'deterministic')

    expect(labels()).toHaveLength(1)
    expect(labels()[0]).toContain('behavior-unit-tests')
  })

  it('a search with no match shows the no-match row instead of the skill rows', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()

    await typeInto(SEARCH, 'nothing-matches-this')

    expect(labels()).toHaveLength(0)
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-no-match"]')).not.toBeNull()
  })

  it('hides nothing permanently: a filtered-out pick comes back when the search clears', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    await clickRow(0)

    await typeInto(SEARCH, 'zig')
    expect(labels()).toHaveLength(1)
    await typeInto(SEARCH, '')

    expect(labels()).toHaveLength(3)
    expect(checkedCount()).toBe(1)
    expect(pickerText()).toContain('pdf')
  })

  it('emits create-and-run with skillNames in pick order', async () => {
    mountDialog()
    await flushPromises()
    await typeInto('[data-testid="kanban-task-detail-create-name"]', 'My task')
    await openPicker()
    await clickRow(0)
    await clickRow(1)

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')?.click()
    await flushPromises()

    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { skillNames: string[] }
    expect(payload.skillNames).toEqual(['pdf', 'zig-trap'])
  })

  it('emits create with the picked skillNames', async () => {
    mountDialog()
    await flushPromises()
    await typeInto('[data-testid="kanban-task-detail-create-name"]', 'My task')
    await openPicker()
    await clickRow(2)

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')?.click()
    await flushPromises()

    const emitted = wrapper!.emitted('create')
    const payload = emitted![0]![0] as { skillNames: string[] }
    expect(payload.skillNames).toEqual(['behavior-unit-tests'])
  })

  it('emits skillNames: [] when nothing is picked (the canonical sentinel)', async () => {
    mountDialog()
    await flushPromises()
    await typeInto('[data-testid="kanban-task-detail-create-name"]', 'My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')?.click()
    await flushPromises()

    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { skillNames: string[] }
    expect(payload.skillNames).toEqual([])
  })

  it('resets the selection and the search when the dialog reopens in create mode', async () => {
    mountDialog()
    await flushPromises()
    await openPicker()
    await clickRow(0)
    await typeInto(SEARCH, 'pdf')

    await wrapper!.setProps({ show: false })
    await wrapper!.setProps({ show: true })
    await flushPromises()

    expect(chips()).toHaveLength(0)
    expect(pickerText()).toContain('None')
    await openPicker()
    expect(findInDom<HTMLInputElement>(SEARCH)?.value).toBe('')
    expect(labels()).toHaveLength(3)
  })

  it('handles api.getSkills failure gracefully (empty list, picker still renders)', async () => {
    vi.spyOn(api, 'getSkills').mockRejectedValue(new Error('boom'))
    mountDialog()
    await flushPromises()

    await openPicker()

    expect(labels()).toHaveLength(0)
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-empty"]')).not.toBeNull()
  })

  it('shows the empty state when the workspace has no skills', async () => {
    vi.spyOn(api, 'getSkills').mockResolvedValue({ skills: [] })
    mountDialog()
    await flushPromises()

    await openPicker()

    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-empty"]')).not.toBeNull()
  })
})

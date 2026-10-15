/**
 * Skill picker in KanbanTaskDetailDialog (create mode only).
 * Mount pattern: same as KanbanTaskDetailDialog.profile.spec.ts.
 */
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
]

describe('KanbanTaskDetailDialog — skill picker (Migration 110)', () => {
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

  async function typeName(name: string) {
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
    if (!input) throw new Error('name input missing')
    input.value = name
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
  }

  it('renders the skill picker button in create mode', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker"]')).not.toBeNull()
  })

  it('does NOT render the skill picker in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker"]')).toBeNull()
  })

  it('button label defaults to "None"', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')
    expect(btn?.textContent).toContain('None')
  })

  it('clicking the picker opens a dropdown with None + each skill', async () => {
    mountDialog()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-dropdown"]')).not.toBeNull()
    const items = findAllInDom('[data-testid="kanban-task-detail-skill-picker-item"]')
    // "None" + the two seeded skills.
    expect(items.length).toBe(3)
    expect(items[0]?.textContent).toContain('None')
    expect(items[1]?.textContent).toContain('pdf')
    expect(items[2]?.textContent).toContain('zig-trap')
  })

  it('selecting a skill updates the button label', async () => {
    mountDialog()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    const skillItem = findAllInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-skill-picker-item"]',
    )[1]
    skillItem?.click()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')
    expect(btn?.textContent).toContain('pdf')
  })

  it('emits create-and-run with skillName after a skill is picked', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    findAllInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-skill-picker-item"]',
    )[1]?.click()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { skillName: string }
    expect(payload.skillName).toBe('pdf')
  })

  it('emits create with skillName for plain create', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    findAllInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-skill-picker-item"]',
    )[2]?.click()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { skillName: string }
    expect(payload.skillName).toBe('zig-trap')
  })

  it('emits skillName="" when no skill is picked (the canonical sentinel)', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { skillName: string }
    expect(payload.skillName).toBe('')
  })

  it('resets the selection when the dialog reopens in create mode', async () => {
    mountDialog()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    findAllInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-skill-picker-item"]',
    )[1]?.click()
    await flushPromises()
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.textContent,
    ).toContain('pdf')

    // Close, then reopen — the picker must start blank again.
    await wrapper!.setProps({ show: false })
    await wrapper!.setProps({ show: true })
    await flushPromises()
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.textContent,
    ).toContain('None')
  })

  it('handles api.getSkills failure gracefully (empty list, picker still renders)', async () => {
    vi.spyOn(api, 'getSkills').mockRejectedValue(new Error('boom'))
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')
    expect(btn).not.toBeNull()
    btn?.click()
    await flushPromises()
    const items = findAllInDom('[data-testid="kanban-task-detail-skill-picker-item"]')
    // Only the "None" row survives a failed fetch.
    expect(items.length).toBe(1)
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-empty"]')).not.toBeNull()
  })

  it('shows the empty state when the workspace has no skills', async () => {
    vi.spyOn(api, 'getSkills').mockResolvedValue({ skills: [] })
    mountDialog()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-skill-picker"]')?.click()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-skill-picker-empty"]')).not.toBeNull()
  })
})

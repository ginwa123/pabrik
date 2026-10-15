/** Tests for the profile-model picker in KanbanTaskDetailDialog
 * (create mode only).
 * Mount pattern: same as KanbanTaskDetailDialog.runAgent.spec.ts —
 * <Teleport to="body">, attachTo: document.body + document.querySelector.
 * Plan: docs/superpowers/plans/2026-08-06-kanban-task-profile-selector.md
 *   Task 1 / Step 1.1 */
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

describe('KanbanTaskDetailDialog — profile picker', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
      profiles: {
        '900r1bu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
      },
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
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
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  it('renders the profile picker button in create mode', async () => {
    mountDialog()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker"]'),
    ).not.toBeNull()
  })

  it('does NOT render the profile picker in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker"]'),
    ).toBeNull()
  })

  it('button label defaults to "Default"', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    expect(btn?.textContent).toContain('Default')
  })

  it('clicking the picker opens a dropdown with Default + each profile', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-profile-picker-dropdown"]'),
    ).not.toBeNull()
    const items = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )
    expect(items.length).toBe(2)
    expect(items[0]?.textContent).toContain('Default')
    expect(items[1]?.textContent).toContain('900r1bu')
  })

  it('selecting a profile updates the button label', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    expect(btn?.textContent).toContain('900r1bu')
  })

  it('emits create-and-run with selectedProfile after a profile is picked', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    runBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('900r1bu')
  })

  it('emits create with selectedProfile for plain create', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    btn?.click()
    await flushPromises()
    const profileItem = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )[1] as HTMLButtonElement
    profileItem?.click()
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    saveBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create')
    expect(emitted).toBeTruthy()
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('900r1bu')
  })

  it('emits create-and-run with selectedProfile="" when Default is selected', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    runBtn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { selectedProfile: string }
    expect(payload.selectedProfile).toBe('')
  })

  it('handles api.getPabrikConfig failure gracefully (no profiles)', async () => {
    vi.spyOn(api, 'getPabrikConfig').mockRejectedValue(new Error('boom'))
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-profile-picker"]',
    )
    expect(btn).not.toBeNull()
    btn?.click()
    await flushPromises()
    const items = findAllInDom(
      '[data-testid="kanban-task-detail-profile-picker-item"]',
    )
    expect(items.length).toBe(1)
    expect(items[0]?.textContent).toContain('Default')
  })
})

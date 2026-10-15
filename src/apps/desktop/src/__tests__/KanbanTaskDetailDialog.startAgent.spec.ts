/**
 * Tests for the "Start agent" button in KanbanTaskDetailDialog (edit mode).
 *
 * Mount pattern: same as KanbanTaskDetailDialog.runAgent.spec.ts —
 * <Teleport to="body">, so use `attachTo: document.body` +
 * `document.querySelector` (NOT `wrapper.find`).
 *
 * Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task } from '@/stores/workspaces'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — Start agent', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  /**
   * Mount the dialog with optional props and an optional `processingState`
   * provider. The `processingState` map mirrors the one App.vue
   * provides — a Record<sessionId, boolean> where `true` means a
   * worker is currently running for that session. Assigns to the
   * outer `wrapper` so the afterEach hook can unmount it.
   */
  function mountDialog(
    propsOverride: Record<string, unknown> = {},
    processingState: Record<string, boolean> | undefined = undefined,
  ) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'edit', ...propsOverride },
      global: {
        // Only include processingState when the test passes one — the dialog's
        // `inject('processingState', undefined)` falls back to undefined when absent, so the "no
        // provider" branch is also exercised by omitting this key.
        provide: processingState !== undefined ? { processingState } : {},
      },
    })
    return wrapper
  }

  it('renders the start-agent button in edit mode', async () => {
    mountDialog({ task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-start-agent"]')).not.toBeNull()
  })

  it('does NOT render the start-agent button in create mode', async () => {
    // Create mode has its own ▶ Create task & run agent button. The
    // edit-mode Start agent button would be redundant + confusing.
    mountDialog({ mode: 'create', task: null })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-start-agent"]')).toBeNull()
    // Sanity: create-mode button is present.
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).not.toBeNull()
  })

  it('disables the start-agent button when processingState[task.id] is true', async () => {
    mountDialog(
      { task: { id: 'task_running', name: 'Running', task_type: 'standard' } as Task },
      { task_running: true },
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    expect(btn?.disabled).toBe(true)
  })

  it('enables the start-agent button when processingState[task.id] is false', async () => {
    mountDialog(
      { task: { id: 'task_idle', name: 'Idle', task_type: 'standard' } as Task },
      { task_idle: false },
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    expect(btn?.disabled).toBe(false)
  })

  it('enables the start-agent button when processingState has no entry for the task', async () => {
    // processingState is provided but doesn't contain this task's id —
    // the dialog treats the absence as "no worker running".
    mountDialog(
      { task: { id: 'task_orphan', name: 'Orphan', task_type: 'standard' } as Task },
      { task_other: true },
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    expect(btn?.disabled).toBe(false)
  })

  it('enables the start-agent button when no processingState is provided at all', async () => {
    // Defensive: the dialog's `inject('processingState', undefined)` defaults to undefined when the
    // provider is missing (e.g. tests that mount the dialog in isolation). The button must still be
    // enabled — we don't want to break the dialog if a future refactor forgets to provide the map.
    mountDialog(
      { task: { id: 'task_no_provider', name: 'NoProvider', task_type: 'standard' } as Task },
      undefined,
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    expect(btn?.disabled).toBe(false)
  })

  it('emits start-agent with { taskId } on click', async () => {
    mountDialog(
      { task: { id: 'task_click', name: 'Click me', task_type: 'standard' } as Task },
      {},
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('start-agent')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([{ taskId: 'task_click' }])
  })

  it('does NOT emit start-agent when the worker is running (button disabled)', async () => {
    mountDialog(
      { task: { id: 'task_busy', name: 'Busy', task_type: 'standard' } as Task },
      { task_busy: true },
    )
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    // `disabled` buttons drop the click event in the browser — we mimic
    // that by calling .click() and asserting the absence of an emit.
    // (Calling .click() on a disabled button in jsdom is a no-op.)
    btn?.click()
    await flushPromises()
    expect(wrapper!.emitted('start-agent')).toBeUndefined()
  })
})

/** Tests for the "Create task & run agent" button in KanbanTaskDetailDialog (create mode). Mount
 * pattern: same as KanbanTaskDetailDialog.spec.ts. <Teleport to="body">, so use `attachTo:
 * document.body` + `document.querySelector` (NOT `wrapper.find`). */
/** Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md Task 2 / Step 2.1 */
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

describe('KanbanTaskDetailDialog — Create task & run agent', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  it('renders the create-and-run button in create mode', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).not.toBeNull()
  })

  it('does NOT render the create-and-run button in edit mode', async () => {
    mountDialog({
      mode: 'edit',
      task: { id: 'task_1', name: 'Existing', task_type: 'standard' } as Task,
    })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).toBeNull()
  })

  it('disables the create-and-run button when name is empty', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    expect(btn?.disabled).toBe(true)
  })

  it('enables the create-and-run button when name is non-empty (description may be empty)', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task title'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    expect(btn?.disabled).toBe(false)
  })

  it('emits create-and-run with mode create_and_run on click', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    const desc = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-create-description"]',
    )
    if (!input || !desc) throw new Error('inputs missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    desc.value = 'Body of the task'
    desc.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create_and_run',
        name: 'My task',
        description: 'Body of the task',
        is_auto_retry_until_stop: '1',
        // Default OFF — the dialog's worktree toggle was not flipped.
        useGitWorktree: false,
        worktreePath: '',
        // No base ref — no `Base:` line in the queue_message.
        worktreeBaseBranch: '',
        tags: [],
        // NEW (plan: 2026-08-06-kanban-task-profile-selector)
        selectedProfile: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
        // NEW (Migration 070 — kanban-cwd-session-optional plan).
        // Empty string = no per-task cwd. See comment on the
        // earlier "emits create" test for the full rationale.
        cwdSession: '',
      },
    ])
  })

  it('forwards unattended toggle value into the emit payload', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'My task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    // The toggle's @change handler reads target.checked; flip it
    // to true so the change event reflects the user "turning it on".
    if (toggle) toggle.checked = true
    toggle?.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { is_auto_retry_until_stop: '0' | '1' }
    expect(payload.is_auto_retry_until_stop).toBe('1')
  })

  it('defaults unattended mode to ON in create mode', async () => {
    mountDialog()
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle?.checked).toBe(true)
  })

  it('emits create-and-run with unattended ON by default (no toggle interaction)', async () => {
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
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    btn?.click()
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    const payload = emitted![0]![0] as { is_auto_retry_until_stop: '0' | '1' }
    expect(payload.is_auto_retry_until_stop).toBe('1')
  })

  it('pressing Enter in the name input auto create-and-runs the agent', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    if (!input) throw new Error('name input missing')
    input.value = 'Enter task'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }))
    // Vue Test Utils keyup.enter listener: trigger via keyup with key Enter
    await flushPromises()
    const emitted = wrapper!.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    expect(wrapper!.emitted('create')).toBeUndefined()
  })

  it('does NOT emit create-and-run when name is empty (button disabled)', async () => {
    mountDialog()
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    btn?.click()
    await flushPromises()
    expect(wrapper!.emitted('create-and-run')).toBeUndefined()
  })
})

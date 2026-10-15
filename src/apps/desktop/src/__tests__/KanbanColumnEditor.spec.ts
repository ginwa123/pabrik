/**
 * Tests for KanbanColumnEditor — the modal that handles add / rename
 * / delete of a kanban column. One component, three modes (mode prop).
 *
 * Mounts with attachTo: document.body + inspects the teleported content
 * via document.querySelector (same pattern as AddKanbanDialog.spec.ts
 * and AddTaskPickerDialog.spec.ts).
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 6 / Task 6.2
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import KanbanColumnEditor from '../components/kanban/KanbanColumnEditor.vue'

type Mode = 'add' | 'rename' | 'delete'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function mountEditor(
  mode: Mode,
  initialShow = true,
  initialName?: string,
) {
  document.body.innerHTML = ''
  return mount(KanbanColumnEditor, {
    attachTo: document.body,
    props: {
      show: initialShow,
      mode,
      initialName,
    },
  })
}

describe('KanbanColumnEditor', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  // ─── mode='add' ──────────────────────────────────────────────────────────

  describe("mode='add'", () => {
    it('shows the "Add Column" header and a name input', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const dialog = findInDom('[data-testid="kanban-column-editor-add"]')
      expect(dialog).not.toBeNull()
      expect(dialog?.textContent).toContain('Add Column')
      expect(dialog?.textContent).toContain('Add a new column to this kanban board')
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-add-name"]',
      )
      expect(nameInput).not.toBeNull()
      expect(nameInput?.value).toBe('')
    })

    it('Add button is disabled when name is empty', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const btn = findInDom<HTMLButtonElement>(
        '[data-testid="kanban-column-editor-add-submit"]',
      )
      expect(btn?.disabled).toBe(true)
    })

    it('Add button is enabled when a non-empty name is typed', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-add-name"]',
      )!
      nameInput.value = 'In review'
      nameInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushPromises()
      const btn = findInDom<HTMLButtonElement>(
        '[data-testid="kanban-column-editor-add-submit"]',
      )
      expect(btn?.disabled).toBe(false)
    })

    it('emits add(name) and close when Add is clicked with a valid name', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-add-name"]',
      )!
      nameInput.value = 'In review'
      nameInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-add-submit"]')
      expect(wrapper.emitted('add')?.[0]).toEqual(['In review', ''])
      expect(wrapper.emitted('close')).toBeTruthy()
    })

    it('trims whitespace before emitting add(name)', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-add-name"]',
      )!
      nameInput.value = '  In review  '
      nameInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-add-submit"]')
      expect(wrapper.emitted('add')?.[0]).toEqual(['In review', ''])
    })

    it('emits close when Cancel is clicked (no add)', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-add-cancel"]')
      expect(wrapper.emitted('close')).toBeTruthy()
      expect(wrapper.emitted('add')).toBeUndefined()
    })

    it('emits close on Escape', async () => {
      wrapper = mountEditor('add')
      await flushPromises()
      const dialog = findInDom<HTMLElement>('[data-testid="kanban-column-editor-add"]')
      dialog?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      expect(wrapper.emitted('close')).toBeTruthy()
    })
  })

  // ─── mode='rename' ───────────────────────────────────────────────────────

  describe("mode='rename'", () => {
    it('pre-fills the name input with the initial column name', async () => {
      wrapper = mountEditor('rename', true, 'todo')
      await flushPromises()
      const dialog = findInDom('[data-testid="kanban-column-editor-rename"]')
      expect(dialog).not.toBeNull()
      expect(dialog?.textContent).toContain('Rename Column')
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-rename-name"]',
      )
      expect(nameInput?.value).toBe('todo')
    })

    it('emits rename(name) and close when Save is clicked', async () => {
      wrapper = mountEditor('rename', true, 'todo')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-rename-name"]',
      )!
      nameInput.value = 'Backlog'
      nameInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-rename-submit"]')
      expect(wrapper.emitted('rename')?.[0]).toEqual(['Backlog', '', false])
      expect(wrapper.emitted('close')).toBeTruthy()
    })

    it('Save button is disabled when name is whitespace-only', async () => {
      wrapper = mountEditor('rename', true, 'todo')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-rename-name"]',
      )!
      nameInput.value = '   '
      nameInput.dispatchEvent(new Event('input', { bubbles: true }))
      await flushPromises()
      const btn = findInDom<HTMLButtonElement>(
        '[data-testid="kanban-column-editor-rename-submit"]',
      )
      expect(btn?.disabled).toBe(true)
    })
  })

  // ─── mode='delete' ───────────────────────────────────────────────────────

  describe("mode='delete'", () => {
    it('shows confirmation message with the column name', async () => {
      wrapper = mountEditor('delete', true, 'todo')
      await flushPromises()
      const dialog = findInDom('[data-testid="kanban-column-editor-delete"]')
      expect(dialog).not.toBeNull()
      expect(dialog?.textContent).toContain('Delete Column')
      expect(dialog?.textContent).toContain('Tasks in this column will become unassigned')
      // The column name is rendered in the confirmation message.
      const message = findInDom('[data-testid="kanban-column-editor-delete-message"]')
      expect(message?.textContent).toContain('todo')
    })

    it('does NOT render a name input in delete mode', async () => {
      wrapper = mountEditor('delete', true, 'todo')
      await flushPromises()
      const nameInput = findInDom<HTMLInputElement>(
        '[data-testid="kanban-column-editor-delete-name"]',
      )
      expect(nameInput).toBeNull()
    })

    it('emits delete() and close when Delete is clicked', async () => {
      wrapper = mountEditor('delete', true, 'todo')
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-delete-submit"]')
      expect(wrapper.emitted('delete')).toBeTruthy()
      expect(wrapper.emitted('close')).toBeTruthy()
    })

    it('emits close when Cancel is clicked (no delete)', async () => {
      wrapper = mountEditor('delete', true, 'todo')
      await flushPromises()
      clickInDom('[data-testid="kanban-column-editor-delete-cancel"]')
      expect(wrapper.emitted('close')).toBeTruthy()
      expect(wrapper.emitted('delete')).toBeUndefined()
    })
  })

  // ─── show=false (any mode) ───────────────────────────────────────────────

  describe('show=false', () => {
    it('renders nothing in any mode', () => {
      wrapper = mountEditor('add', false)
      expect(findInDom('[data-testid="kanban-column-editor-add"]')).toBeNull()

      wrapper = mountEditor('rename', false)
      expect(findInDom('[data-testid="kanban-column-editor-rename"]')).toBeNull()

      wrapper = mountEditor('delete', false)
      expect(findInDom('[data-testid="kanban-column-editor-delete"]')).toBeNull()
    })
  })
})

// ─── description field (Chunk 2 of kanban-column-description-settings) ─────

describe('KanbanColumnEditor description field', () => {
  afterEach(() => {
    document.body.innerHTML = ''
    document.body.style.overflow = ''
  })

  // Note: tests in this block use document.querySelector (via
  // findInDom) instead of wrapper.find() because the editor renders
  // inside <Teleport to="body"> — Vue Test Utils' wrapper.find() does
  // not traverse the teleport destination. Same convention as the
  // existing tests at the top of this file.

  it('shows a description textarea in add mode', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: { show: true, mode: 'add' },
    })
    await flushPromises()
    const desc = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-column-editor-add-description"]',
    )
    expect(desc).not.toBeNull()
    expect(desc?.tagName).toBe('TEXTAREA')
    wrapper.unmount()
  })

  it('emits add with the description when Add is clicked', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: { show: true, mode: 'add' },
    })
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="kanban-column-editor-add-name"]',
    )!
    nameInput.value = 'Review'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const descInput = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-column-editor-add-description"]',
    )!
    descInput.value = 'Awaiting code review — must pass CI'
    descInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="kanban-column-editor-add-submit"]')
    const emitted = wrapper.emitted('add')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Review', 'Awaiting code review — must pass CI'])
    wrapper.unmount()
  })

  it('emits rename with the description when Save is clicked', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'rename',
        initialName: 'todo',
        initialDescription: 'Not started',
      },
    })
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="kanban-column-editor-rename-name"]',
    )!
    nameInput.value = 'backlog'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const descInput = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-column-editor-rename-description"]',
    )!
    descInput.value = 'Newly triaged items'
    descInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="kanban-column-editor-rename-submit"]')
    const emitted = wrapper.emitted('rename')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['backlog', 'Newly triaged items', false])
    wrapper.unmount()
  })

  it('seeds description from initialDescription prop on open', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: {
        show: false,
        mode: 'rename',
        initialDescription: 'Pre-existing meaning',
      },
    })
    await flushPromises()
    await wrapper.setProps({ show: true })
    await flushPromises()
    const descInput = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-column-editor-rename-description"]',
    )
    expect(descInput?.value).toBe('Pre-existing meaning')
    wrapper.unmount()
  })

  it('rename mode shows the is-done checkbox, pre-filled from initialIsDone', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: { show: true, mode: 'rename', initialName: 'done', initialIsDone: true },
    })
    await flushPromises()
    const box = findInDom<HTMLInputElement>(
      '[data-testid="kanban-column-editor-rename-is-done"]',
    )
    expect(box).not.toBeNull()
    expect(box?.checked).toBe(true)
    wrapper.unmount()
  })

  it('rename mode forwards the checkbox state as the third rename arg', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: { show: true, mode: 'rename', initialName: 'done' },
    })
    await flushPromises()
    const box = findInDom<HTMLInputElement>(
      '[data-testid="kanban-column-editor-rename-is-done"]',
    )!
    box.checked = true
    box.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="kanban-column-editor-rename-submit"]')
    expect(wrapper.emitted('rename')?.[0]).toEqual(['done', '', true])
    wrapper.unmount()
  })

  it('add mode does NOT render the is-done checkbox', async () => {
    document.body.innerHTML = ''
    const wrapper = mount(KanbanColumnEditor, {
      attachTo: document.body,
      props: { show: true, mode: 'add' },
    })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-column-editor-add-is-done"]')).toBeNull()
    wrapper.unmount()
  })
})
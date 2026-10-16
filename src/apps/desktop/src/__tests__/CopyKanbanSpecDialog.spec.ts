/** Tests for CopyKanbanSpecDialog — the per-board "copy spec from another kanban" modal. Mount
 * pattern: same as KanbanSettingsDialog.spec.ts (Teleport + attachTo: document.body +
 * document.querySelector for DOM assertions). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import CopyKanbanSpecDialog from '@/components/dialogs/CopyKanbanSpecDialog.vue'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '@/stores/workspaces'
import * as api from '@/api'

// Mock the api module so the source-columns preview fetch doesn't
// hit a real backend. Default: return an empty list. Tests can
// override per-case via mockResolvedValueOnce.
vi.mock('@/api', async () => {
  const actual = await vi.importActual<typeof api>('@/api')
  return {
    ...actual,
    listKanbanColumns: vi.fn().mockResolvedValue({ columns: [], count: 0 }),
  }
})

const source1: WorkspaceItem = {
  id: 'wi_src_1',
  name: 'Sprint 12 (template)',
  item_type: 'kanban',
  path: null,
}

const source2: WorkspaceItem = {
  id: 'wi_src_2',
  name: 'Bug triage',
  item_type: 'kanban',
  path: null,
}

const target: WorkspaceItem = {
  id: 'wi_target',
  name: 'Local Sprint',
  item_type: 'kanban',
  path: null,
}

const workspace: Workspace = {
  id: 'ws_test',
  name: 'Test workspace',
  icon: '📂',
  items: [source1, source2, target],
  expanded: true,
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

describe('CopyKanbanSpecDialog', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
    setActivePinia(createPinia())
    const store = useWorkspacesStore()
    store.workspaces = [workspace]
    vi.clearAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body
      .querySelectorAll('[data-testid="copy-kanban-spec-dialog"]')
      .forEach((el) => el.remove())
  })

  function mountDialog() {
    // Mount with show: false, then flip to true — the component's watcher on `() => props.show`
    // only fires on a transition, and this is the lifecycle hook that auto-selects the first source
    // (matches the convention in AddKanbanDialog.spec.ts).
    wrapper = mount(CopyKanbanSpecDialog, {
      attachTo: document.body,
      props: {
        show: false,
        workspaceId: 'ws_test',
        targetItemId: 'wi_target',
      },
    })
    return wrapper
  }

  async function openDialog() {
    const w = mountDialog()
    await w.setProps({ show: true })
    await flushPromises()
    return w
  }

  /**    * The custom dropdown starts CLOSED. Tests that need to see options click the trigger first, then
   * await flushPromises so the v-if reactively renders the listbox. */
  async function openDropdown() {
    clickInDom('[data-testid="copy-kanban-spec-source-trigger"]')
    await flushPromises()
  }

  it('renders the dialog with the right title', async () => {
    await openDialog()
    const dialog = findInDom<HTMLElement>('[data-testid="copy-kanban-spec-dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.textContent).toContain('Copy spec from')
  })

  it('excludes the target from the source picker', async () => {
    await openDialog()
    await openDropdown()
    const listbox = findInDom<HTMLElement>(
      '[data-testid="copy-kanban-spec-source-list"]',
    )
    expect(listbox).not.toBeNull()
    // Filter out empty-state list item, only count real options.
    const optionButtons = listbox!.querySelectorAll<HTMLButtonElement>(
      'button[data-testid^="copy-kanban-spec-source-option-"]',
    )
    const ids = Array.from(optionButtons).map((b) =>
      b.getAttribute('data-testid')!.replace('copy-kanban-spec-source-option-', ''),
    )
    expect(ids).toContain('wi_src_1')
    expect(ids).toContain('wi_src_2')
    expect(ids).not.toContain('wi_target')
  })

  it('defaults to replace mode', async () => {
    await openDialog()
    const replaceRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-replace"]',
    )
    expect(replaceRadio?.checked).toBe(true)
  })

  it('emits copy with the selected source and mode on Confirm', async () => {
    const w = await openDialog()
    const appendRadio = findInDom<HTMLInputElement>(
      '[data-testid="copy-kanban-spec-mode-append"]',
    )
    appendRadio!.checked = true
    appendRadio!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()

    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()

    const emitted = w!.emitted('copy')
    expect(emitted).toBeTruthy()
    // Alphabetical sort: "Bug triage" (wi_src_2) precedes
    // "Sprint 12 (template)" (wi_src_1), so auto-selection picks
    // wi_src_2 on open.
    expect(emitted![0]).toEqual(['wi_src_2', 'append'])
  })

  it('emits copy with the explicitly-picked source after dropdown click', async () => {
    const w = await openDialog()
    // Open the custom dropdown and click the second option.
    await openDropdown()
    clickInDom('[data-testid="copy-kanban-spec-source-option-wi_src_1"]')
    await flushPromises()

    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()

    const emitted = w!.emitted('copy')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['wi_src_1', 'replace'])
  })

  it('emits close on Cancel and on backdrop click', async () => {
    const w = await openDialog()
    clickInDom('[data-testid="copy-kanban-spec-cancel"]')
    await flushPromises()
    expect(w!.emitted('close')).toBeTruthy()
  })

  it('disables the confirm button when no sources are available', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { ...workspace, items: [target] },
    ]
    const w = await openDialog()
    await flushPromises()

    // The dropdown isn't open by default, so check the empty-state
    // marker indirectly via the disabled Confirm button.
    const confirmBtn = findInDom<HTMLButtonElement>(
      '[data-testid="copy-kanban-spec-confirm"]',
    )
    expect(confirmBtn?.disabled).toBe(true)
    clickInDom('[data-testid="copy-kanban-spec-confirm"]')
    await flushPromises()
    expect(w!.emitted('copy')).toBeFalsy()

    // Open the dropdown — the empty-state message should be visible.
    await openDropdown()
    const emptyMsg = findInDom<HTMLElement>(
      '[data-testid="copy-kanban-spec-empty"]',
    )
    expect(emptyMsg).not.toBeNull()
  })

  it('renders the source column preview when source has columns', async () => {
    vi.mocked(api.listKanbanColumns).mockResolvedValueOnce({
      columns: [
        { id: 'col_a', name: 'Todo', description: 'pending', position: 0, workspace_item_id: 'wi_src_2', created_at: '' },
        { id: 'col_b', name: 'Doing', description: '', position: 1, workspace_item_id: 'wi_src_2', created_at: '' },
      ],
      count: 2,
    })
    await openDialog()
    await flushPromises()
    await flushPromises() // allow the async loadSourceColumns to settle
    const preview = document.body.textContent ?? ''
    expect(preview).toContain('2 columns will be copied')
    expect(preview).toContain('Todo')
    expect(preview).toContain('pending')
  })

  it('interpolates the target name in the prompt + radio legend', async () => {
    await openDialog()
    const text = document.body.textContent ?? ''
    expect(text).toContain('Local Sprint')
    // The radio legend should reference the target's actual name.
    expect(text).toMatch(/What should happen to Local Sprint/)
  })
})

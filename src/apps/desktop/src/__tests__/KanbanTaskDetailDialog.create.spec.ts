/** Tests for KanbanTaskDetailDialog — focused, edit-in-place task detail view. Used by the kanban
 * tree to edit a task's name + description with optional metadata (column, type, pinned). Mount
 * pattern: same as KanbanSettingsDialog.spec.ts. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task, KanbanColumn } from '@/stores/workspaces'

const TASK: Task = {
  id: 'task_test_1',
  name: 'Original name',
  description: 'Original description',
  task_type: 'standard',
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

// ─── Column dropdown (create mode) — plan 2026-08-06-kanban-add-task-button-placement ─── Replaces
// the read-only column label in create mode with an interactive dropdown. Mirrors the profile
// picker pattern (button trigger + ▾ dropdown + ✓ checkmark + click-outside close).
describe('KanbanTaskDetailDialog — column dropdown (create mode)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  // Helper: mount the dialog in create mode with the given columns
  // and an optional initial column (defaults to the first).
  function mountCreateWithColumns(
    columns: { id: string; name: string }[],
    initialColumnId: string | null = columns[0]?.id ?? null,
  ): VueWrapper {
    const fullColumns: KanbanColumn[] = columns.map((c) => ({
      id: c.id,
      name: c.name,
      workspace_item_id: 'item_1',
      position: 0,
      created_at: '2026-06-21 12:00:00',
    }))
    const initialColumn = initialColumnId
      ? (fullColumns.find((c) => c.id === initialColumnId) ?? null)
      : null
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: initialColumn,
        availableColumns: fullColumns,
        workspaceId: 'ws_1',
      },
    })
    return wrapper
  }

  it('create mode: column is rendered as a dropdown button (not a static text strip)', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    // Dropdown trigger renders with the expected testid.
    expect(findInDom('[data-testid="kanban-task-detail-column-picker"]')).not.toBeNull()
    // The static strip (legacy testid) does NOT render in create mode.
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).toBeNull()
  })

  it('create mode: column dropdown defaults to the column prop', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    const trigger = findInDom<HTMLElement>('[data-testid="kanban-task-detail-column-picker"]')
    expect(trigger?.textContent).toContain('todo')
  })

  it('create mode: opening the dropdown and picking a column emits column-change', async () => {
    const w = mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()

    // Open the dropdown.
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Pick the second column.
    clickInDom('[data-testid="kanban-task-detail-column-picker-item-col_y"]')
    await flushPromises()

    expect(w.emitted('column-change')).toBeTruthy()
    expect(w.emitted('column-change')?.[0]).toEqual(['col_y'])
  })

  it('create mode: single-column kanban — dropdown renders with the single item + checkmark', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    const item = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_x"]',
    )
    expect(item).not.toBeNull()
    expect(item?.textContent).toContain('✓')
  })

  it('edit mode: column is rendered as a static text strip (no dropdown)', async () => {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'edit',
        task: {
          id: 'task_1',
          name: 'existing task',
          description: '',
          kanban_column_id: 'col_x',
        },
        column: {
          id: 'col_x',
          name: 'todo',
          workspace_item_id: 'item_1',
          position: 0,
          created_at: '2026-06-21 12:00:00',
        },
        availableColumns: [], // edit mode ignores availableColumns
      },
    })
    await flushPromises()
    // Static strip renders (legacy testid).
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).not.toBeNull()
    // Dropdown does NOT render.
    expect(findInDom('[data-testid="kanban-task-detail-column-picker"]')).toBeNull()
  })

  it('create mode: clicking outside the dropdown closes it', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Dropdown is open.
    expect(findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]')).not.toBeNull()
    // Dispatch a click on document.body (outside the picker).
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushPromises()
    // Dropdown is closed.
    expect(findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]')).toBeNull()
  })

  // NEW (kanban panel restructure). The dropdown is no longer an absolutely positioned overlay
  // pinned to the trigger's left edge — it renders IN PLACE, as the next normal-flow block below
  // its trigger. The old pins (min-w-[180px] + left-0 on the dropdown) described the overlay.
  it('create mode: the column dropdown flows under a min-w-[180px] trigger with no width cap', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in_review_planning' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()

    const trigger = findInDom<HTMLElement>('[data-testid="kanban-task-detail-column-picker"]')
    const dropdown = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-dropdown"]',
    )
    expect(trigger).not.toBeNull()
    expect(dropdown).not.toBeNull()

    // Trigger is still a wide button, not a tiny pill.
    const triggerClass = trigger!.getAttribute('class') ?? ''
    expect(triggerClass).toContain('min-w-[180px]')
    expect(triggerClass).toContain('justify-between')

    // The dropdown is an in-flow block sharing the trigger's container, laid out
    // right below it (jsdom has no layout, so "same parent + next element
    // sibling" is the measurable form of "directly below, same width").
    const dropdownClass = dropdown!.getAttribute('class') ?? ''
    expect(dropdownClass).not.toContain('absolute')
    expect(dropdownClass).not.toContain('top-full')
    expect(dropdownClass).not.toContain('z-20')
    // No width cap of its own: an in-flow block fills its column instead.
    expect(dropdownClass).not.toMatch(/(^|\s)(min-w-|max-w-|w-)/)
    expect(dropdown!.parentElement).toBe(trigger!.parentElement)
    expect(trigger!.nextElementSibling).toBe(dropdown!)

    // The items keep their testids (and the profile-picker row style: no per-row separator).
    const item = dropdown!.querySelector<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_y"]',
    )
    expect(item).not.toBeNull()
    const itemStyle = item!.getAttribute('style') ?? ''
    expect(itemStyle).not.toMatch(/border-top/i)
  })
})

describe('KanbanTaskDetailDialog — layout', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(task: Task | null = TASK) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  function mountCreateDialog(cwd: string = '') {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: null,
        cwd,
      },
    })
    return wrapper
  }

  // Regression for the "huge empty space below form" bug. The previous code used `height: min(80vh,
  // calc(100vh - 2rem))` on the dialog card, which forced the dialog to always render at 80vh.
  it('uses max-height (not fixed height) so the dialog shrinks to fit short content', async () => {
    mountDialog()
    await flushPromises()
    const card = document.querySelector<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > div.relative',
    )
    expect(card).not.toBeNull()
    const style = card!.getAttribute('style') ?? ''
    // The fix: max-height caps at 80vh, but the card can shrink below it.
    expect(style).toMatch(/max-height:\s*min\(80vh,\s*calc\(100vh\s*-\s*2rem\)\)/)
    // The bug: a fixed `height: min(80vh, ...)` forced the card to 80vh
    // regardless of content height. Make sure we haven't reintroduced it.
    expect(style).not.toMatch(/(^|[\s;])height:\s*min\(80vh/)
  })

  // User feedback: "make the dialog bigger". The previous `max-w-xl` (576px) was narrow for a
  // multi-field form (task name + column picker + description + tags + folder picker + profile
  // picker + unattended mode).
  it('uses max-w-2xl (bigger) so the form has more horizontal room', async () => {
    mountDialog()
    await flushPromises()
    const card = document.querySelector<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > div.relative',
    )
    expect(card).not.toBeNull()
    const classAttr = card!.getAttribute('class') ?? ''
    expect(classAttr).toContain('max-w-2xl')
    // Make sure we didn't accidentally revert to max-w-xl.
    expect(classAttr).not.toMatch(/(^|\s)max-w-xl(\s|$)/)
  })

  // User feedback: "fix the color font folder". The previous folder picker used the `📂` emoji which
  // renders as a system-colorful icon (orange/yellow) that doesn't match the muted dark theme — the
  // picker looked "out of place" next to the cleaner robot-emoji profile picker.
  it('create mode: folder picker uses an inline SVG icon (not the 📂 emoji)', async () => {
    mountCreateDialog('/home/user/projects/foo')
    await flushPromises()
    const picker = document.querySelector<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    const text = picker!.textContent ?? ''
    // The emoji is gone.
    expect(text).not.toMatch(/📂/)
    // An SVG icon is rendered instead (replaces the emoji span).
    const svg = picker!.querySelector('svg')
    expect(svg).not.toBeNull()
    // The SVG has a sensible folder-icon viewBox.
    expect(svg!.getAttribute('viewBox')).toBe('0 0 20 20')
  })

  // When the cwd is set, the folder picker's text color is bright (`var(--semantic-text)` =
  // #c5c9c5) — not dim — so the picked folder path reads clearly against the dark background.
  it('create mode: folder picker text color is bright when cwd is set', async () => {
    mountCreateDialog('/home/user/projects/foo')
    await flushPromises()
    const picker = document.querySelector<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    // Read the inline style and assert it does NOT use the dim color.
    // The button's color is set via inline style (Vue's :style binding).
    const inlineStyle = picker!.getAttribute('style') ?? ''
    // The new contract: when cwd is set, color is --semantic-text (bright).
    expect(inlineStyle).toMatch(/color:\s*var\(--semantic-text\)/)
    // No dim color when cwd is set.
    expect(inlineStyle).not.toMatch(/color:\s*var\(--semantic-text-dim\)/)
  })

  // When the cwd is NOT set (the "skip" / optional state), the folder picker text stays dim — this
  // is intentional because the path slot shows the "Skip (no project root)" placeholder, which
  // shouldn't look like an active selection.
  it('create mode: folder picker text color is dim when cwd is empty', async () => {
    mountCreateDialog('')
    await flushPromises()
    const picker = document.querySelector<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    const inlineStyle = picker!.getAttribute('style') ?? ''
    expect(inlineStyle).toMatch(/color:\s*var\(--semantic-text-dim\)/)
  })

  // ── cwd picker: open at the right place ───────────────────────────────── User feedback: "fix
  // the folder query" — the per-task cwd picker used to always open at "/" regardless of
  // cwd_session, forcing the user to navigate back to their cwd on every reopen.
  describe('create mode: cwd picker opens at cwd_session (folder query fix)', () => {
    function mockFetchWithFs(
      entries: Record<string, Array<{ name: string; path: string; is_directory: boolean }>>,
    ) {
      return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
        const url = typeof input === 'string' ? input : input.toString()
        const u = new URL(url, 'http://localhost')
        const path = u.searchParams.get('path') ?? ''
        const action = u.searchParams.get('action') ?? 'list'
        if (action !== 'list') {
          return new Response(JSON.stringify({ content: '' }), { status: 200 })
        }
        const data = path
          ? { path: '/', absolute: path, home: '/home/test', entries: entries[path] ?? [] }
          : {
              path: '/',
              absolute: '/home/test',
              home: '/home/test',
              entries: entries['__home__'] ?? [],
            }
        return new Response(JSON.stringify(data), { status: 200 })
      })
    }

    it('when cwd_session is set, the picker opens AT cwd_session (not at "/")', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
        '/home/user': [{ name: 'projects', path: '/home/user/projects', is_directory: true }],
        '/home/user/projects': [
          { name: 'foo', path: '/home/user/projects/foo', is_directory: true },
        ],
        '/home/user/projects/foo': [
          { name: 'src', path: '/home/user/projects/foo/src', is_directory: true },
          {
            name: 'package.json',
            path: '/home/user/projects/foo/package.json',
            is_directory: false,
          },
        ],
      })

      mountCreateDialog('/home/user/projects/foo')
      await flushPromises()
      // Open the picker.
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      // The picker opens on the Recent tab by default (per 2026-08-14-folder-picker-recent-history
      // plan). Switch to Browse to assert that the cwd's children loaded — Recent is empty for a
      // fresh test fixture so we can't see items there.
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // The cwd's children must be in the content pane — proving
      // expandAncestors walked the chain back to cwd_session (not
      // stopping at "/" because the picker opened at cwd_session).
      expect(
        document.querySelector('[data-testid="file-picker-item-/home/user/projects/foo/src"]'),
      ).not.toBeNull()
      // And the cwd breadcrumb is rendered with all four segments.
      const crumbs = document.querySelectorAll('[data-testid^="file-picker-crumb-"]')
      const crumbTexts = Array.from(crumbs).map((el) => el.textContent?.trim())
      expect(crumbTexts).toEqual(['home', 'user', 'projects', 'foo'])
    })

    it('when cwd_session is empty, the picker opens at "/" (root folders visible)', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        __home__: [{ name: 'test', path: '/home/test', is_directory: true }],
      })

      mountCreateDialog('')
      await flushPromises()
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      // Same Recent-vs-Browse dance — the picker opens on Recent
      // by default, switch to Browse to assert root entries.
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // No cwd → picker opens at "/" → listFolder('/') is called →
      // root entries are displayed.
      expect(document.querySelector('[data-testid="file-picker-item-/home"]')).not.toBeNull()
      // The breadcrumb should show just the root.
      const crumbs = document.querySelectorAll('[data-testid^="file-picker-crumb-"]')
      expect(crumbs.length).toBe(0)
    })

    it('cwd_session is pre-selected in the picker so the footer shows the current cwd', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
        '/home/user': [{ name: 'projects', path: '/home/user/projects', is_directory: true }],
        '/home/user/projects': [
          { name: 'foo', path: '/home/user/projects/foo', is_directory: true },
        ],
        '/home/user/projects/foo': [
          { name: 'src', path: '/home/user/projects/foo/src', is_directory: true },
        ],
      })

      mountCreateDialog('/home/user/projects/foo')
      await flushPromises()
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // The footer "Selected:" line should reflect cwd_session so the
      // user sees what they're about to overwrite on Select.
      const selectedPath = document.querySelector('[data-testid="file-picker-selected-path"]')
      expect(selectedPath?.textContent?.trim()).toBe('/home/user/projects/foo')
    })
  })
})

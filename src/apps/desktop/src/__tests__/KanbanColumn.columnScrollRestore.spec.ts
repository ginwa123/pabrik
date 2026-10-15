/**
 * KanbanColumn — per-column vertical scroll survives an unmount/remount.
 *
 * The user-visible bug this pins:
 *   Clicking a kanban task card opens the chat (its own tab). The board
 *   unmounts behind it, so coming back to the board tab rebuilt every column
 *   at `scrollTop = 0` — the user lost their place in a 50-card column. The
 *   same unmount happens with tab mode off, where the chat replaces the board
 *   in the single view.
 *
 * Why stub <VirtualScroller>:
 *   <KanbanColumn> persists the position of the scroller's OWN container
 *   (`containerRef`), which keeps the save/restore logic in the component that
 *   owns it. jsdom has no layout, so a real VirtualScroller reports
 *   scrollHeight = clientHeight = 0 and the clamp would skip every restore.
 *   The stub exposes a plain div as `containerRef` so the test can give that
 *   element real geometry and assert the real wiring: the key, the ref
 *   plumbing, and the round trip.
 *
 * The composable itself is covered in
 * src/composables/__tests__/useKanbanColumnScrollRestore.spec.ts.
 */
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, ref, type Ref } from 'vue'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import KanbanColumnComponent from '../components/kanban/KanbanColumn.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'
const COLUMN_ID = 'col_a'
const KEY = `kanban-col-scroll-${ITEM_ID}:${COLUMN_ID}`

beforeAll(() => {
  // jsdom 29 dropped localStorage from the default globals — install a stub.
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })

  // jsdom does NOT provide requestAnimationFrame — polyfill it via
  // setTimeout(0) so the composable's `await rAF × 2` resolves.
  if (typeof globalThis.requestAnimationFrame !== 'function') {
    globalThis.requestAnimationFrame = (cb: (t: number) => void): number =>
      setTimeout(() => cb(performance.now()), 0) as unknown as number
    globalThis.cancelAnimationFrame = (id: number): void => {
      clearTimeout(id as unknown as ReturnType<typeof setTimeout>)
    }
  }
})

/**  * Stand-in for <VirtualScroller> that exposes a real, geometry-controllable `containerRef`. It
 * deliberately does NOT render the default slot: the cards are irrelevant here and rendering them
 * would drag in KanbanCard's whole prop surface for no benefit. */
const ScrollerStub = defineComponent({
  name: 'VirtualScroller',
  setup(_props, { expose }) {
    const containerRef = ref<HTMLElement | null>(null)
    expose({ containerRef })
    const build = () => h('div', { ref: containerRef, class: 'scroller-stub' })
    return build
  },
})

function makeColumn(): KanbanColumnType {
  return {
    id: COLUMN_ID,
    name: 'in_review_task',
    workspace_item_id: ITEM_ID,
    position: 0,
    created_at: '2026-01-01',
  } as KanbanColumnType
}

function makeTask(id: string): Task {
  return { id, name: id, workspace_item_id: ITEM_ID, kanban_column_id: COLUMN_ID } as Task
}

function setGeometry(el: HTMLElement, scrollHeight: number, clientHeight: number): void {
  Object.defineProperty(el, 'scrollHeight', {
    value: scrollHeight,
    writable: true,
    configurable: true,
  })
  Object.defineProperty(el, 'clientHeight', {
    value: clientHeight,
    writable: true,
    configurable: true,
  })
}

function mountColumn(): VueWrapper {
  const store = useWorkspacesStore()
  const column = makeColumn()
  const tasks = [makeTask('task_1'), makeTask('task_2')]
  store.workspaces = [
    {
      id: WS_ID,
      name: 'Workspace 1',
      icon: '📁',
      expanded: false,
      items: [
        {
          id: ITEM_ID,
          name: 'Kanban',
          item_type: 'kanban',
          path: '/tmp',
          kanban_columns: [column],
          tasks,
        },
      ],
    },
  ] as never

  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanColumnComponent, {
    props: { column, tasks, workspaceId: WS_ID, itemId: ITEM_ID },
    global: {
      provide: { processingState },
      stubs: { VirtualScroller: ScrollerStub },
    },
  })
}

async function waitForRestore(): Promise<void> {
  await flushPromises()
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await new Promise<void>((r) => requestAnimationFrame(() => r()))
  await flushPromises()
}

beforeEach(() => {
  setActivePinia(createPinia())
  vi.spyOn(console, 'warn').mockImplementation(() => {})
})

afterEach(() => {
  vi.restoreAllMocks()
  localStorage.clear()
})

describe('KanbanColumn — per-column vertical scroll persistence', () => {
  it('saves the column scrollTop under an item+column scoped key', async () => {
    const wrapper = mountColumn()
    const container = wrapper.find('.scroller-stub').element as HTMLElement
    setGeometry(container, 5000, 800)
    await flushPromises()

    container.scrollTop = 640
    container.dispatchEvent(new Event('scroll'))
    container.dispatchEvent(new Event('scrollend'))

    expect(localStorage.getItem(KEY)).toBe('640')
    wrapper.unmount()
  })

  it('restores the scrollTop when the board is remounted (the tab-switch case)', async () => {
    // First visit: the user scrolls a long column.
    const first = mountColumn()
    const firstContainer = first.find('.scroller-stub').element as HTMLElement
    setGeometry(firstContainer, 5000, 800)
    await flushPromises()
    firstContainer.scrollTop = 1750
    firstContainer.dispatchEvent(new Event('scroll'))
    firstContainer.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem(KEY)).toBe('1750')

    // The board unmounts — switching to the task-chat tab, then back.
    first.unmount()

    setActivePinia(createPinia())
    const second = mountColumn()
    const secondContainer = second.find('.scroller-stub').element as HTMLElement
    setGeometry(secondContainer, 5000, 800)

    await waitForRestore()

    expect(secondContainer.scrollTop).toBe(1750)
    second.unmount()
  })

  it('does not leak a position across boards or columns', async () => {
    const wrapper = mountColumn()
    const container = wrapper.find('.scroller-stub').element as HTMLElement
    setGeometry(container, 5000, 800)
    await flushPromises()

    container.scrollTop = 500
    container.dispatchEvent(new Event('scroll'))
    container.dispatchEvent(new Event('scrollend'))

    // Exactly one key, named for this board's column — a key that could only
    // ever describe one board's one column.
    expect(localStorage.getItem(KEY)).toBe('500')
    expect(localStorage.getItem('kanban-col-scroll-item_2:col_a')).toBeNull()
    expect(localStorage.getItem(`kanban-col-scroll-${ITEM_ID}:col_b`)).toBeNull()

    wrapper.unmount()
  })
})

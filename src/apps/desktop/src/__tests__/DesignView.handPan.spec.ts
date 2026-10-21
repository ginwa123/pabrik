/** Behavioral tests for DesignView.vue's hand-mode (Space + drag to pan). 4 tests covering: 1.
 * Holding Space sets body cursor to grab. 2. Releasing Space restores the default cursor. 3. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import DesignView from '../components/design/DesignView.vue'
import type { WorkspaceItem } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function makeItem(): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Test',
    item_type: 'design',
    path: '/tmp/test',
    design_elements: [],
  }
}

describe('DesignView hand-mode pan', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    // DesignView's onMounted calls loadPages() which calls
    // listDesignPages -> fetch. Return a valid page so the canvas
    // container renders and we can target it from the tests.
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: () =>
        Promise.resolve({
          pages: [
            {
              id: 'page_1',
              workspace_item_id: ITEM_ID,
              name: 'Test Page',
              width: 1440,
              height: 1024,
              position: 0,
              created_at: '2026-07-19 00:00:00',
              updated_at: '2026-07-19 00:00:00',
            },
          ],
          count: 1,
        }),
      text: () => Promise.resolve(''),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
    // Each test starts with a fresh body cursor.
    document.body.style.cursor = ''
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
    document.body.style.cursor = ''
    // Clean up any inputs created by the input-guard test.
    document
      .querySelectorAll('input[data-testid="hand-pan-test-input"]')
      .forEach((el) => el.remove())
  })

  it('holding Space sets body cursor to grab', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    expect(document.body.style.cursor).toBe('grab')
    wrapper.unmount()
  })

  it('releasing Space restores the default cursor', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    expect(document.body.style.cursor).toBe('grab')
    document.dispatchEvent(new KeyboardEvent('keyup', { key: ' ' }))
    expect(document.body.style.cursor).toBe('')
    wrapper.unmount()
  })

  it('Space inside an INPUT does NOT enter grab mode', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    const input = document.createElement('input')
    input.setAttribute('data-testid', 'hand-pan-test-input')
    document.body.appendChild(input)
    input.focus()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
    expect(document.body.style.cursor).toBe('')
    wrapper.unmount()
  })

  it('pointer-drag on the canvas with Space held updates scrollLeft/scrollTop', async () => {
    const wrapper = mount(DesignView, {
      props: { item: makeItem(), workspaceId: WS_ID, itemId: ITEM_ID },
    })
    await flushPromises()
    const container = wrapper
      .find('[data-testid="design-canvas-scroll-container"]')
      .element as HTMLElement
    // jsdom doesn't fully implement pointer capture / scroll properties
    // — stub them so the drag math runs deterministically.
    container.setPointerCapture = () => {}
    container.releasePointerCapture = () => {}
    container.hasPointerCapture = () => true
    let scrollLeft = 0
    let scrollTop = 0
    Object.defineProperty(container, 'scrollLeft', {
      get: () => scrollLeft,
      set: (v: number) => {
        scrollLeft = v
      },
    })
    Object.defineProperty(container, 'scrollTop', {
      get: () => scrollTop,
      set: (v: number) => {
        scrollTop = v
      },
    })
    // Capture the pointermove listener registered inside startCanvasPan
    // so we can simulate it directly (faster + more deterministic than
    // dispatching PointerEvents through the html element).
    let onMove: ((e: PointerEvent) => void) | null = null
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    container.addEventListener = ((type: string, cb: any) => {
       
      if (type === 'pointermove') onMove = cb
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    }) as any

    // Enter Space + start the pan.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }))
    expect(document.body.style.cursor).toBe('grab')

    container.dispatchEvent(
      new PointerEvent('pointerdown', {
        clientX: 100,
        clientY: 100,
        button: 0,
        pointerId: 1,
        bubbles: true,
      }),
    )
    expect(document.body.style.cursor).toBe('grabbing')
    expect(onMove).not.toBeNull()

    // Simulate a 50-px-left, 20-px-up drag — the canvas should have scrolled +50 horizontally and
    // +20 vertically (cursor delta is subtracted from the original scroll position, so a leftward
    // drag with a positive delta increases scrollLeft).
    onMove!(
      new PointerEvent('pointermove', {
        clientX: 50,
        clientY: 80,
        pointerId: 1,
      }),
    )
    expect(container.scrollLeft).toBe(50)
    expect(container.scrollTop).toBe(20)

    // And a second drag updates again, not from the captured snap.
    onMove!(
      new PointerEvent('pointermove', {
        clientX: 30,
        clientY: 50,
        pointerId: 1,
      }),
    )
    expect(container.scrollLeft).toBe(70)
    expect(container.scrollTop).toBe(50)
    wrapper.unmount()
  })
})

/** Behavioural mount tests for `DesignElement.vue::elementStyle::zIndex`. */
/** SYMPTOM (2026-08-06, task_1785988530202): the right-click reorder menu (Bring to front / forward
 * / Send backward / back) and the keyboard shortcuts (Ctrl+]/[) updated `z_index` in the DB
 * correctly but the canvas visual stacking didn't change. */
/** ROOT CAUSE: `DesignElement.vue::elementStyle` did NOT include `zIndex`. For `position: absolute`
 * elements without explicit z-index CSS, DOM order = visual stacking. */
/** The frontend's `reorderDesignElements` mirrors the backend response IN-PLACE (preserves array
 * order), so the DOM order doesn't change either. Net: z_index changes in DB but visual stacking
 * stays the same. FIX: add `zIndex: props.element.z_index` to the elementStyle computed object. */
/** CSS then handles the stacking correctly. These tests verify the WIRE contract: the wrapper's
 * inline `style` attribute contains `z-index: <z_index>px` for every element, so CSS stacking
 * matches the database's z_index. */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'

import DesignElement from '../components/design/DesignElement.vue'
import type { DesignElement as DesignElementApi } from '../api'

// Minimal mock element. The ShapeValidator in DesignElement.vue does
// not run on direct mount (it's only called when the parent canvas
// writes back a geometry update), so a minimal shape is enough.
function makeElement(overrides: Partial<DesignElementApi> = {}): DesignElementApi {
  return {
    id: 'elem_test',
    page_id: 'page_test',
    name: 'test-element',
    type: 'rectangle',
    file_path: '',
    x: 0,
    y: 0,
    width: 100,
    height: 100,
    rotation: 0,
    fill: '#000000',
    stroke: '',
    stroke_width: 0,
    corner_radius: 0,
    opacity: 1,
    text_content: '',
    text_style: '',
    image_url: '',
    parent_id: '',
    z_index: 0,
    position: 0,
    created_at: '',
    updated_at: '',
    ...overrides,
  }
}

describe('DesignElement.vue — elementStyle applies z_index as inline CSS z-index', () => {
  let wrapper: VueWrapper | null = null

// Pinia is required because `DesignElement.vue::setup` now imports `useWorkspacesStore` (added
// 2026-08-06 so the element can look up its parent for the "click on child → select parent"
// redirect).
// The store is created here but remains empty — the lookup returns null for any element, which the
// component treats as "no parent found → safe-degrade to existing behaviour" (select the element
// itself, no z-index impact). See DesignElement.drag.spec.ts for the parent-found tests.
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  // The wrapper div carries the dynamic testid `design-element-<id>` AND a static
  // `data-design-element="true"` attribute (per the component's contract at lines 732-733). Use the
  // static attribute for test selectors so a change in element.id doesn't break the test.
  const rootSelector = '[data-design-element="true"]'

  it('renders inline z-index: 0 for an element with z_index=0', async () => {
    wrapper = mount(DesignElement, {
      props: { element: makeElement({ z_index: 0 }) },
    })
    await nextTick()
    const style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/z-index:\s*0\b/)
  })

  it('renders inline z-index: 5 for an element with z_index=5 (regression: must apply, not be dropped)', async () => {
    wrapper = mount(DesignElement, {
      props: { element: makeElement({ z_index: 5 }) },
    })
    await nextTick()
    const style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/z-index:\s*5\b/)
  })

  it('renders inline z-index: -1 for an element with z_index=-1 (negative z-index is valid)', async () => {
    wrapper = mount(DesignElement, {
      props: { element: makeElement({ z_index: -1 }) },
    })
    await nextTick()
    const style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/z-index:\s*-1\b/)
  })

  it('reactively updates z-index when element.z_index changes (Bring to front → z_index bumps → CSS updates)', async () => {
    const element = makeElement({ z_index: 0 })
    wrapper = mount(DesignElement, { props: { element } })
    await nextTick()
    let style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/z-index:\s*0\b/)

    // Simulate the store mirror after Bring to front: parent_id stays
    // "", array order stays the same, but z_index bumped to 7.
    await wrapper.setProps({ element: makeElement({ z_index: 7 }) })
    await nextTick()
    style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/z-index:\s*7\b/)
  })

  it('still applies left/top/width/height/transform/opacity (regression guard for the existing 6 fields)', async () => {
    wrapper = mount(DesignElement, {
      props: {
        element: makeElement({
          x: 50,
          y: 75,
          width: 200,
          height: 120,
          rotation: 45,
          opacity: 0.6,
          z_index: 3,
        }),
      },
    })
    await nextTick()
    const style = wrapper.find(rootSelector).attributes('style') ?? ''
    expect(style).toMatch(/left:\s*50px/)
    expect(style).toMatch(/top:\s*75px/)
    expect(style).toMatch(/width:\s*200px/)
    expect(style).toMatch(/height:\s*120px/)
    expect(style).toMatch(/transform:\s*rotate\(45deg\)/)
    expect(style).toMatch(/opacity:\s*0\.6/)
    expect(style).toMatch(/z-index:\s*3\b/)
  })
})

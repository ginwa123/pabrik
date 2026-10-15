/** Tests for the AddTaskPickerDialog — two large cards shown when the user clicks the green `+`
 * button on a workspace item. The parent (Sidebar) decides which creation flow to open based on the
 * `pick` event payload. */

/** Note on `attachTo: document.body` + `document.querySelector`: AddTaskPickerDialog uses <Teleport
 * to="body"> to render the dialog at the document root. */

/** With `mount({ attachTo: document.body })`, vue-test-utils' wrapper still references the mount
 * target as `wrapper.element` (the empty `<div data-v-app>`); the teleported content lives as a
 * sibling of that div under document.body. So `wrapper.find('[data-testid=...]')` returns empty. */

/** The ImagePreview spec follows the same pattern (uses `document.querySelector` to inspect
 * teleported content); we do the same here. */

/** Element interactions also use the native `element.click()` (the ImagePreview precedent) so the
 * event reaches the listener attached to the document-attached DOM node. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import AddTaskPickerDialog from '../components/dialogs/AddTaskPickerDialog.vue'

describe('AddTaskPickerDialog', () => {
  let wrapper: VueWrapper | null = null

  // Inline type matches the component's defineProps<{ show: boolean; projectName?: string }> — we
  // can't import the type directly from a Vue SFC, so we duplicate the shape here. The test only
  // ever passes `{ show: boolean }`, so this is sufficient.
  function mountPicker(props: { show: boolean; projectName?: string }) {
    const w = mount(AddTaskPickerDialog, {
      props,
      attachTo: document.body,
    })
    wrapper = w
    return w
  }

  beforeEach(() => {
    // No pinia / localStorage needed — this is a pure presentational
    // component.
  })

  afterEach(() => {
    // attachTo: document.body leaves the teleported DOM in
    // document.body between tests. Clean up so the next test sees
    // a fresh tree.
    wrapper?.unmount()
    wrapper = null
    // Defensive: force-remove any leftover teleported nodes (mirrors
    // the ImagePreview spec's afterEach at imagePreview.spec.ts:44).
    document.querySelectorAll('[data-testid="add-task-picker"]').forEach((el) => el.remove())
  })

  it('does not render anything when show=false', () => {
    mountPicker({ show: false })
    expect(document.querySelector('[data-testid="add-task-picker"]')).toBeNull()
  })

  it('renders both cards when show=true', async () => {
    mountPicker({ show: true })
    // Two ticks: first for the v-if to render, second for the
    // <Transition> wrapper to commit.
    await wrapper!.vm.$nextTick()
    expect(document.querySelector('[data-testid="add-task-picker"]')).not.toBeNull()
    expect(document.querySelector('[data-testid="picker-standard"]')).not.toBeNull()
    expect(document.querySelector('[data-testid="picker-routine"]')).toBeNull()
    expect(document.querySelector('[data-testid="picker-memory"]')).not.toBeNull()
    // Human-readable labels present
    expect(document.body.textContent).toContain('Standard Chat')
    expect(document.body.textContent).toContain('Memory')
  })

  it('emits pick="standard" when the Standard Chat card is clicked', async () => {
    const w = mountPicker({ show: true })
    await w.vm.$nextTick()
    const card = document.querySelector<HTMLElement>('[data-testid="picker-standard"]')!
    expect(card).toBeTruthy()
    card.click()
    expect(w.emitted('pick')).toBeDefined()
    expect(w.emitted('pick')!.length).toBe(1)
    expect(w.emitted('pick')![0]).toEqual(['standard'])
    // The picker is a chooser: it must self-close on pick so the picked create dialog isn't stacked
    // on top of it. This guards the regression where the picker stayed open after picking and ended
    // up covering the chat view after the create callback completed.
    expect(w.emitted('close')).toBeDefined()
    expect(w.emitted('close')!.length).toBe(1)
  })

  it('emits pick="memory" when the Memory card is clicked', async () => {
    // The Memory card was added in 2026-06-20 (plan: docs/plans/
    // 2026-06-20-add-markdown-memory.md). It opens a flow where the user creates a local .md file
    // and a task row pointing at it (via AddMemoryDialog in mode='task' → addTask).
    const w = mountPicker({ show: true })
    await w.vm.$nextTick()
    const card = document.querySelector<HTMLElement>('[data-testid="picker-memory"]')!
    expect(card).toBeTruthy()
    card.click()
    expect(w.emitted('pick')).toBeDefined()
    expect(w.emitted('pick')!.length).toBe(1)
    expect(w.emitted('pick')![0]).toEqual(['memory'])
    // Same self-close contract as the other two cards — see the
    // assertion in the standard-card test above.
    expect(w.emitted('close')).toBeDefined()
    expect(w.emitted('close')!.length).toBe(1)
  })

  it('emits close when the Cancel button is clicked', async () => {
    const w = mountPicker({ show: true })
    await w.vm.$nextTick()
    // The Cancel button is the only one in the footer; the cards
    // are <button>s in the body, so the footer button is the one
    // outside any [data-testid] card. We use text matching.
    const cancelBtn = Array.from(document.querySelectorAll<HTMLElement>('button')).find(
      (b) => b.textContent?.trim() === 'Cancel',
    )
    expect(cancelBtn).toBeDefined()
    cancelBtn!.click()
    expect(w.emitted('close')).toBeDefined()
  })
})

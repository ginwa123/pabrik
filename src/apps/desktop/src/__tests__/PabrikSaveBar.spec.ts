import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PabrikSaveBar from '../components/pabrik/PabrikSaveBar.vue'

describe('PabrikSaveBar', () => {
  it('renders nothing when not dirty', () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: false, unsavedCount: 0, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(false)
  })

  it('renders the dirty pill with the count when dirty', () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 3, saving: false },
    })
    expect(wrapper.find('[data-testid="save-bar"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('3 unsaved changes')
  })

  it('uses singular "change" when unsavedCount is 1', () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    expect(wrapper.text()).toContain('1 unsaved change')
    expect(wrapper.text()).not.toContain('1 unsaved changes')
  })

  it('emits reset when the Reset button is clicked', async () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="reset-btn"]').trigger('click')
    expect(wrapper.emitted('reset')).toBeTruthy()
  })

  it('emits save when the Save button is clicked', async () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: false },
    })
    await wrapper.find('[data-testid="save-btn"]').trigger('click')
    expect(wrapper.emitted('save')).toBeTruthy()
  })

  it('pins itself to the TOP of the pane, with the separator on its bottom edge', () => {
    // The bar used to sit at the BOTTOM of the settings pane, which put the
    // only save/reset controls below a section the user has to scroll
    // through. It is now mounted above the scrollable content, so the
    // classes have to describe a top-pinned bar: `top-0`, not `bottom-0`,
    // and the divider on the edge that faces the content.
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 2, saving: false },
    })
    const bar = wrapper.find('[data-testid="save-bar"]')
    expect(bar.classes()).toContain('sticky')
    expect(bar.classes()).toContain('top-0')
    expect(bar.classes()).not.toContain('bottom-0')
    expect(bar.classes()).toContain('border-b')
    expect(bar.classes()).not.toContain('border-t')
  })

  it('disables both buttons when saving is true', () => {
    const wrapper = mount(PabrikSaveBar, {
      props: { dirty: true, unsavedCount: 1, saving: true },
    })
    expect((wrapper.find('[data-testid="reset-btn"]').element as HTMLButtonElement).disabled).toBe(true)
    expect((wrapper.find('[data-testid="save-btn"]').element as HTMLButtonElement).disabled).toBe(true)
  })
})

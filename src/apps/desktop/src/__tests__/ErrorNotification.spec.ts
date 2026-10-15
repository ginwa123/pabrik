/** ErrorNotification.spec.ts
 * Unit tests for the `ErrorNotification` toast component.
 * Covers: message rendering, details accordion (shown / hidden),
 * dismiss emission, and the role="alert" a11y contract. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import ErrorNotification from '../components/preview/ErrorNotification.vue'

describe('ErrorNotification', () => {
  it('renders the message', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Server returned 500' },
    })
    expect(wrapper.text()).toContain('Server returned 500')
  })

  it('hides the details accordion when details prop is absent', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Plain error' },
    })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('shows the details accordion when details prop is set', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Server returned 500', details: 'Internal Server Error' },
    })
    expect(wrapper.find('details').exists()).toBe(true)
    expect(wrapper.find('details').text()).toContain('Internal Server Error')
  })

  it('clicking × emits dismiss', async () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'Click me away' },
    })
    await wrapper.find('button[aria-label="Dismiss"]').trigger('click')
    expect(wrapper.emitted('dismiss')).toHaveLength(1)
  })

  it('has role="alert" for screen readers', () => {
    const wrapper = mount(ErrorNotification, {
      props: { message: 'A11y matters' },
    })
    expect(wrapper.attributes('role')).toBe('alert')
  })
})

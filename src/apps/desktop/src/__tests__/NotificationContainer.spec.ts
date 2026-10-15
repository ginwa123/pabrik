/**  * NotificationContainer.spec.ts Unit tests for the `NotificationContainer` stack renderer. Covers:
 * empty state, one-toast-per-store-entry, and the dismiss wiring (× click → store.dismiss(id)). */
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import NotificationContainer from '../components/shell/NotificationContainer.vue'
import { useNotificationStore } from '../stores/notifications'

describe('NotificationContainer', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders nothing when store is empty', () => {
    const wrapper = mount(NotificationContainer)
    expect(wrapper.findAll('[role="alert"]')).toHaveLength(0)
  })

  it('renders one ErrorNotification per store entry', () => {
    const store = useNotificationStore()
    store.notifyError('first')
    store.notifyError('second')
    const wrapper = mount(NotificationContainer)
    expect(wrapper.findAll('[role="alert"]')).toHaveLength(2)
    expect(wrapper.text()).toContain('first')
    expect(wrapper.text()).toContain('second')
  })

  it('clicking × on a toast calls store.dismiss(id)', async () => {
    const store = useNotificationStore()
    store.notifyError('dismiss me')
    const wrapper = mount(NotificationContainer)
    await wrapper.find('button[aria-label="Dismiss"]').trigger('click')
    expect(store.notifications).toHaveLength(0)
  })
})

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { mount } from '@vue/test-utils'

import MobileShell from '../components/appLayout/MobileShell.vue'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'

beforeEach(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  setActivePinia(createPinia())
})

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {}, path: '/app', fullPath: '/app', params: {}, name: 'app' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

const renderShell = (props: { mobile?: boolean } = {}) => mount(MobileShell, { props })

describe('MobileShell', () => {
  it('renders nothing on a desktop viewport', () => {
    const wrapper = renderShell({ mobile: false })
    expect(wrapper.find('[data-testid="mobile-top-bar"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="mobile-nav-backdrop"]').exists()).toBe(false)
  })

  it('shows a top bar with a menu button on a phone', () => {
    const wrapper = renderShell({ mobile: true })
    expect(wrapper.find('[data-testid="mobile-top-bar"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="mobile-nav-toggle"]').exists()).toBe(true)
  })

  it('keeps the content undimmed until the drawer is asked for', () => {
    const wrapper = renderShell({ mobile: true })
    expect(wrapper.find('[data-testid="mobile-nav-backdrop"]').exists()).toBe(false)
  })

  it('opens the drawer from the menu button', async () => {
    const wrapper = renderShell({ mobile: true })
    await wrapper.get('[data-testid="mobile-nav-toggle"]').trigger('click')
    expect(useNavigationStore().mobileNavOpen).toBe(true)
    expect(wrapper.find('[data-testid="mobile-nav-backdrop"]').exists()).toBe(true)
  })

  it('closes the drawer when the dimmed content is tapped', async () => {
    const wrapper = renderShell({ mobile: true })
    await wrapper.get('[data-testid="mobile-nav-toggle"]').trigger('click')
    await wrapper.get('[data-testid="mobile-nav-backdrop"]').trigger('click')
    expect(useNavigationStore().mobileNavOpen).toBe(false)
  })

  it('closes the drawer when Escape is pressed', async () => {
    const wrapper = renderShell({ mobile: true })
    await wrapper.get('[data-testid="mobile-nav-toggle"]').trigger('click')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await wrapper.vm.$nextTick()
    expect(useNavigationStore().mobileNavOpen).toBe(false)
    wrapper.unmount()
  })
})

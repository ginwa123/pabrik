import { describe, it, expect, beforeEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
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

describe('navigation mobile drawer', () => {
  it('starts closed', () => {
    expect(useNavigationStore().mobileNavOpen).toBe(false)
  })

  it('opens on openMobileNav', () => {
    const nav = useNavigationStore()
    nav.openMobileNav()
    expect(nav.mobileNavOpen).toBe(true)
  })

  it('closes on closeMobileNav', () => {
    const nav = useNavigationStore()
    nav.openMobileNav()
    nav.closeMobileNav()
    expect(nav.mobileNavOpen).toBe(false)
  })

  it('flips on toggleMobileNav', () => {
    const nav = useNavigationStore()
    nav.toggleMobileNav()
    expect(nav.mobileNavOpen).toBe(true)
    nav.toggleMobileNav()
    expect(nav.mobileNavOpen).toBe(false)
  })

  it('leaves the desktop sidebar collapse state alone', () => {
    const nav = useNavigationStore()
    const before = nav.sidebarCollapsed
    nav.openMobileNav()
    expect(nav.sidebarCollapsed).toBe(before)
    nav.closeMobileNav()
    expect(nav.sidebarCollapsed).toBe(before)
  })

  it('reopens closed after a reload, so a phone never lands in the drawer', () => {
    useNavigationStore().openMobileNav()
    setActivePinia(createPinia())
    expect(useNavigationStore().mobileNavOpen).toBe(false)
  })
})

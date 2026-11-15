import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import { makeLocalStorageStub } from './helpers'

beforeEach(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
    params: {} as Record<string, string>,
    name: 'app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock, useRouter: useRouterMock }
})

type SidebarProps = {
  collapsed?: boolean
  width?: number
  mobile?: boolean
  mobileOpen?: boolean
}

function renderSidebar(props: SidebarProps = {}) {
  setActivePinia(createPinia())
  return mount(Sidebar, { shallow: true, props })
}

const asideOf = (wrapper: ReturnType<typeof renderSidebar>) =>
  wrapper.get('aside').element as HTMLElement

const styleOf = (el: HTMLElement) => el.getAttribute('style') ?? ''

describe('Sidebar as a phone drawer', () => {
  it('parks off the left edge while it is closed', () => {
    const aside = asideOf(renderSidebar({ mobile: true, mobileOpen: false }))
    expect(styleOf(aside)).toContain('position: fixed')
    expect(styleOf(aside)).toContain('translateX(-100%)')
  })

  it('slides over the content while it is open', () => {
    const aside = asideOf(renderSidebar({ mobile: true, mobileOpen: true }))
    expect(styleOf(aside)).toContain('position: fixed')
    expect(styleOf(aside)).toContain('translateX(0)')
  })

  it('never squeezes the page: no column width is left behind on a phone', () => {
    const aside = asideOf(renderSidebar({ mobile: true, mobileOpen: false, width: 288 }))
    expect(styleOf(aside)).not.toContain('288px')
    expect(styleOf(aside)).toContain('88vw')
    expect(styleOf(aside)).toContain('max-width: 320px')
  })

  it('offers a close button instead of the desktop collapse chevron', () => {
    const wrapper = renderSidebar({ mobile: true, mobileOpen: true })
    expect(wrapper.find('[data-testid="sidebar-mobile-close"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-collapse-toggle"]').exists()).toBe(false)
  })

  it('drops the drag-to-resize handle, which has no meaning under a thumb', () => {
    const wrapper = renderSidebar({ mobile: true, mobileOpen: true })
    expect(wrapper.find('.cursor-col-resize').exists()).toBe(false)
  })

  it('reports the close to the shell so the drawer state has one owner', async () => {
    const wrapper = renderSidebar({ mobile: true, mobileOpen: true })
    await wrapper.get('[data-testid="sidebar-mobile-close"]').trigger('click')
    expect(wrapper.emitted('closeMobileNav')).toHaveLength(1)
  })

  it('shows the full panel even when the desktop sidebar was collapsed to a rail', () => {
    const wrapper = renderSidebar({ mobile: true, mobileOpen: true, collapsed: true })
    expect(wrapper.find('[data-testid="sidebar-header-expanded"]').exists()).toBe(true)
  })
})

describe('Sidebar on a desktop', () => {
  it('keeps its place in the layout and its saved width', () => {
    const aside = asideOf(renderSidebar({ width: 288 }))
    expect(styleOf(aside)).toContain('288px')
    expect(styleOf(aside)).not.toContain('position: fixed')
  })

  it('still collapses to the 64px rail', () => {
    const aside = asideOf(renderSidebar({ width: 288, collapsed: true }))
    expect(styleOf(aside)).toContain('64px')
  })

  it('keeps the collapse chevron and the resize handle', () => {
    const wrapper = renderSidebar({ width: 288 })
    expect(wrapper.find('[data-testid="sidebar-collapse-toggle"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="sidebar-mobile-close"]').exists()).toBe(false)
    expect(wrapper.find('.cursor-col-resize').exists()).toBe(true)
  })
})

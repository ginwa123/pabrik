/** The Projects/Documents divider. The report was that the Projects list grows without limit and
 * pushes Documents out of reach — the Recent/Projects divider already lets a user set how much of
 * the panel Recent takes, so this one has to do the same for Projects. */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'

import Sidebar from '../components/shell/Sidebar.vue'
import { useSidebarStore } from '../stores/sidebar'
import { makeLocalStorageStub } from './helpers'

const NAV_HEIGHT_PX = 600
const SECTION_HEIGHT_PX = 200

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

function renderSidebar() {
  setActivePinia(createPinia())
  return mount(Sidebar, { shallow: true })
}

function projectsSection(wrapper: ReturnType<typeof renderSidebar>): HTMLElement {
  const section = wrapper.find('[data-testid="projects-section"]').element as HTMLElement
  section.getBoundingClientRect = () =>
    ({ height: SECTION_HEIGHT_PX, top: 0, bottom: SECTION_HEIGHT_PX }) as DOMRect
  Object.defineProperty(section.parentElement as HTMLElement, 'clientHeight', {
    value: NAV_HEIGHT_PX,
    configurable: true,
  })
  return section
}

async function dragDivider(wrapper: ReturnType<typeof renderSidebar>, fromY: number, toY: number) {
  const handle = wrapper.find('[data-testid="projects-resize-handle"]')
  handle.element.dispatchEvent(new MouseEvent('mousedown', { clientY: fromY, bubbles: true }))
  document.dispatchEvent(new MouseEvent('mousemove', { clientY: toY }))
  document.dispatchEvent(new MouseEvent('mouseup'))
  await nextTick()
}

describe('the Projects/Documents divider', () => {
  it('leaves the projects section as tall as its rows until the divider is dragged', () => {
    const wrapper = renderSidebar()
    const section = projectsSection(wrapper)
    expect(section.style.height).toBe('')
    expect(useSidebarStore().projectsHeight).toBeNull()
  })

  it('makes the projects section taller when the divider is dragged down', async () => {
    const wrapper = renderSidebar()
    const section = projectsSection(wrapper)

    await dragDivider(wrapper, 300, 400)

    expect(useSidebarStore().projectsHeight).toBeCloseTo(50, 5)
    expect(parseFloat(section.style.height)).toBeCloseTo(50, 5)
  })

  it('makes the projects section shorter when the divider is dragged up', async () => {
    const wrapper = renderSidebar()
    const section = projectsSection(wrapper)

    await dragDivider(wrapper, 300, 200)

    expect(useSidebarStore().projectsHeight).toBeCloseTo(16.67, 1)
    expect(parseFloat(section.style.height)).toBeCloseTo(16.67, 1)
  })

  it('gives the space back to the rows when the divider is double-clicked', async () => {
    const wrapper = renderSidebar()
    const section = projectsSection(wrapper)
    await dragDivider(wrapper, 300, 400)
    expect(section.style.height).not.toBe('')

    await wrapper.find('[data-testid="projects-resize-handle"]').trigger('dblclick')

    expect(useSidebarStore().projectsHeight).toBeNull()
    expect(section.style.height).toBe('')
  })

  it('sits between the projects section and the documents section', () => {
    const wrapper = renderSidebar()
    const nav = wrapper.find('nav').element as Element
    const projects = nav.querySelector('[data-testid="projects-section"]')
    const handle = nav.querySelector('[data-testid="projects-resize-handle"]')
    const documents = nav.querySelector('documents-list-stub')

    expect(projects).not.toBeNull()
    expect(handle).not.toBeNull()
    expect(documents).not.toBeNull()
    expect(projects!.compareDocumentPosition(handle!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
    expect(handle!.compareDocumentPosition(documents!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })
})

describe('the projects section height', () => {
  it('clamps a dragged height to the allowed range', () => {
    setActivePinia(createPinia())
    const store = useSidebarStore()

    store.setProjectsHeight(2)
    expect(store.projectsHeight).toBe(10)

    store.setProjectsHeight(95)
    expect(store.projectsHeight).toBe(80)
  })

  it('survives a reload', () => {
    setActivePinia(createPinia())
    useSidebarStore().setProjectsHeight(35)

    setActivePinia(createPinia())
    expect(useSidebarStore().projectsHeight).toBe(35)
  })

  it('is forgotten when the divider is reset', () => {
    setActivePinia(createPinia())
    const store = useSidebarStore()
    store.setProjectsHeight(35)

    store.setProjectsHeight(null)

    expect(store.projectsHeight).toBeNull()
    setActivePinia(createPinia())
    expect(useSidebarStore().projectsHeight).toBeNull()
  })
})

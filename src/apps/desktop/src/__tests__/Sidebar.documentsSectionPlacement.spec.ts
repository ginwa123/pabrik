/**
 * The sidebar's scroll ownership — why this file exists.
 *
 * The report was "the Documents section sits at the bottom of the sidebar
 * and is far away from Projects". The cause was purely geometric:
 *
 *     <nav class="flex-1 flex flex-col overflow-hidden">
 *       <ChatsList />                                  shrink-0
 *       <div class="flex-1 min-h-0 overflow-hidden">   ← absorbed ALL leftover height
 *         <ProjectsList />
 *       </div>
 *       <DocumentsList />                               shrink-0  ← always last, always bottom
 *     </nav>
 *
 * `flex-1` on the Projects wrapper made that section exactly as tall as
 * the space the other two did not need. With a short project list that is
 * a screen-tall EMPTY box, and Documents — documented as living BELOW
 * Projects — is stranded at the bottom of the viewport.
 *
 * These read the RENDERED dom (shallow mount, children stubbed) rather
 * than grepping the .vue source: the classes that decide the layout are
 * the ones the browser sees, and a comment or a reformatted template can
 * never make this pass or fail by accident. jsdom has no layout engine,
 * so the measuring half — an actual pixel gap — lives in
 * `tests/functional_ui/sidebar_documents_placement_test.py`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import { useSidebarStore } from '../stores/sidebar'
import { makeLocalStorageStub } from './helpers'

// jsdom 29 dropped localStorage from its globals and the sidebar stores
// read it during setup.
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

/**  * Shallow mount: the nav, its wrapper divs and their class strings render for real; the child
 * components are stubbed, because the assertion is about the geometry contract between them, not
 * their contents. */
function renderSidebar() {
  setActivePinia(createPinia())
  return mount(Sidebar, {
    shallow: true,
    global: {
      stubs: {
        // The collapsed rail is a different layout and is not under test.
        Sidebar: false,
      },
    },
  })
}

/** Whitespace-separated Tailwind classes off a rendered element. */
const classesOf = (el: Element | null): string[] =>
  (el?.getAttribute('class') ?? '').split(/\s+/).filter(Boolean)

/** Classes that make an element a vertical scroll container of its own. */
const isScroller = (el: Element | null): boolean =>
  ['overflow-y-auto', 'overflow-y-scroll', 'overflow-auto', 'overflow-scroll'].some((c) =>
    classesOf(el).includes(c),
  )

/** Classes that let a flex item absorb the free space of its container. */
const grows = (el: Element | null): boolean =>
  ['flex-1', 'grow', 'flex-grow', 'grow-0'].some((c) => classesOf(el).includes(c)) &&
  !classesOf(el).includes('grow-0')

describe('sidebar scroll ownership', () => {
  it('renders the nav as the one vertical scroller', () => {
    const nav = renderSidebar().find('nav').element as Element
    expect(isScroller(nav)).toBe(true)
    expect(classesOf(nav)).toContain('min-h-0')
    // `overflow-hidden` with no auto/scroll counterpart is what made the
    // panel a fixed-height stack whose leftover space had to go SOMEWHERE
    // — and it went to Projects.
    expect(classesOf(nav)).not.toContain('overflow-hidden')
  })

  it('gives the nav exactly one scroll container', () => {
    const nav = renderSidebar().find('nav').element as Element
    const scrollers = [...nav.querySelectorAll('*')].filter(isScroller)
    // Shallow mount stubs the children, so the real sections are not in
    // this tree; what is asserted is that the nav does not hand the job
    // to a wrapper of its own on top of itself.
    expect(scrollers.filter((el) => el !== nav)).toEqual([])
  })

  it('does not let the Projects wrapper grow into the gap above Documents', () => {
    const nav = renderSidebar().find('nav').element as Element
    const projects = nav.querySelector('projects-list-stub')
    expect(projects).not.toBeNull()

    // The element directly wrapping ProjectsList, in either the real
    // component name or the stub's.
    const wrapper = projects!.parentElement as Element
    expect(wrapper).not.toBe(nav)
    expect(grows(wrapper)).toBe(false)
    expect(classesOf(wrapper)).toContain('shrink-0')
  })

  it('renders Documents after Projects, inside the same nav', () => {
    const nav = renderSidebar().find('nav').element as Element
    const projects = nav.querySelector('projects-list-stub')
    const documents = nav.querySelector('documents-list-stub')
    expect(projects).not.toBeNull()
    expect(documents).not.toBeNull()
    expect(projects!.compareDocumentPosition(documents!)).toBe(Node.DOCUMENT_POSITION_FOLLOWING)
  })
})

describe('the two sidebar sections that must not scroll themselves', () => {
  it('Projects renders no scroller of its own', async () => {
    const ProjectsList = (await import('../components/workspace/ProjectsList.vue')).default
    setActivePinia(createPinia())
    const wrapper = mount(ProjectsList, {
      props: { workspace: null, activeWorkspaceItemId: null },
      shallow: true,
      global: { stubs: { RouterLink: true } },
    })
    expect(isScroller(wrapper.element)).toBe(false)
    expect([...wrapper.element.querySelectorAll('*')].filter(isScroller)).toEqual([])
  })

  it('Documents renders no max-height capped scroller of its own', async () => {
    const DocumentsList = (await import('../components/workspace/DocumentsList.vue')).default
    setActivePinia(createPinia())
    // The body is behind `v-if="documentsExpanded"`, so without this the
    // assertion would run against an empty section and pass vacuously —
    // which is exactly how the 30vh cap survived every earlier review.
    useSidebarStore().documentsExpanded = true
    const wrapper = mount(DocumentsList, { props: { workspaceId: 'ws_x' }, shallow: true })
    expect(wrapper.find('[data-testid="documents-section-body"]').exists()).toBe(true)

    const capped = [...wrapper.element.querySelectorAll('*')].filter((el) =>
      classesOf(el).some((c) => c.startsWith('max-h-')),
    )
    expect(capped).toEqual([])
    expect([...wrapper.element.querySelectorAll('*')].filter(isScroller)).toEqual([])
  })
})

import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

// The landing navigates with the app router only after a successful
// create — the spec mocks it (the real `/app/:workspaceId` route is
// registered elsewhere; components never touch router files).
const { push } = vi.hoisted(() => ({ push: vi.fn() }))
vi.mock('vue-router', () => ({ useRouter: () => ({ push }) }))

import Chats from '../components/views/Chats.vue'
import { useWorkspacesStore } from '../stores/workspaces'

/** The landing page is a static brand page with ONE affordance (spec:
 * docs/superpowers/specs/2026-09-13-home-landing-design.md, amended by the 2026-09-22 revamp plan —
 * `/app` now creates workspaces). */

/** Three of these tests are SCOPE GUARDS: the user removed the composer, the actions and the modes
 * strip, and the page used to fake an assistant turn — so a future "just one quick action", a
 * reintroduced canned message, or a chat list should fail here rather than ship. */

/** The create-workspace form is the deliberate, asserted exception. */

describe('Chats — Pabrik landing page', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    push.mockClear()
  })

  it('introduces Pabrik with a wordmark, a tagline and the blurb', () => {
    const wrapper = mount(Chats)

    expect(wrapper.find('[data-testid="home-landing"]').exists()).toBe(true)
    expect(wrapper.find('h1[data-testid="home-wordmark"]').text()).toBe('pabrik')
    expect(wrapper.find('[data-testid="home-tagline"]').text()).toBe('AI agent workspace')

    const blurb = wrapper.find('[data-testid="home-blurb"]').text()
    expect(blurb).toContain('AI agent workspace')
    expect(blurb).toContain('kanban')
    expect(blurb).toContain('canvas')
  })

  it('uses a single h1 so the page has a heading outline', () => {
    const wrapper = mount(Chats)
    expect(wrapper.findAll('h1')).toHaveLength(1)
  })

  it('no longer fakes an assistant turn (scope guard)', () => {
    const wrapper = mount(Chats)
    // the old stub rendered this string with a `new Date()` timestamp, so it
    // looked like a real reply that could never be answered
    expect(wrapper.text()).not.toContain('AI coding assistant')
    expect(wrapper.text()).not.toContain('How can I help you today')
  })

  it('creates a workspace and navigates to /app/<id>', async () => {
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addWorkspace').mockResolvedValue('ws_new')

    const wrapper = mount(Chats)
    await wrapper.find('[data-testid="home-workspace-name"]').setValue('My Workspace')
    await wrapper.find('[data-testid="home-create-workspace"]').trigger('submit')
    await flushPromises()

    expect(addSpy).toHaveBeenCalledWith('My Workspace')
    expect(push).toHaveBeenCalledWith('/app/ws_new')
  })

  it('does nothing on an empty or whitespace-only name', async () => {
    const store = useWorkspacesStore()
    const addSpy = vi.spyOn(store, 'addWorkspace').mockResolvedValue('ws_new')

    const wrapper = mount(Chats)
    await wrapper.find('[data-testid="home-workspace-name"]').setValue('   ')
    await wrapper.find('[data-testid="home-create-workspace"]').trigger('submit')
    await flushPromises()

    expect(addSpy).not.toHaveBeenCalled()
    expect(push).not.toHaveBeenCalled()
  })

  it('stays inert: no composer, no messages, no chat list (scope guard)', () => {
    const wrapper = mount(Chats)
    expect(wrapper.find('textarea').exists()).toBe(false)
    expect(wrapper.find('ul').exists()).toBe(false)
    expect(wrapper.find('ol').exists()).toBe(false)
    // The only input is the workspace-name field — no composer/query box.
    const inputs = wrapper.findAll('input')
    expect(inputs).toHaveLength(1)
    expect(inputs[0]!.attributes('data-testid')).toBe('home-workspace-name')
    // The only button is the create submit — no quick actions strip.
    const buttons = wrapper.findAll('button')
    expect(buttons).toHaveLength(1)
    expect(buttons[0]!.attributes('data-testid')).toBe('home-create-workspace-submit')
  })

  it('keeps a one-line hint that points at workspace items as the starting point', () => {
    const wrapper = mount(Chats)
    expect(wrapper.text()).toContain('Create a workspace, then start a project')
  })
})

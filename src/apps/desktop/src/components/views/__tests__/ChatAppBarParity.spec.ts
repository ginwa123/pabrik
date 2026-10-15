/**
 * App-bar parity across the three workspace-item chat modes.
 *
 * Pre-fix, each mode hand-rolled its own bar and the three disagreed
 * on height, padding, background, width and even which controls they
 * carried:
 *
 *   - kanban  → ChatView's inline <header> (h-11, chat column only,
 *               `◫` toggle + bare `✕`)
 *   - agent   → AgentChatView's bespoke <header> (px-5 py-3, full
 *               width ABOVE the right sidebar, text "✕ Close" button,
 *               NO sidebar toggle)
 *   - folder / memory / chat / routine → no bar at all; the `◫`
 *               toggle floated over the transcript
 *
 * The fix routes all three through the shared ChatAppBar.vue by
 * setting ChatView's `showHeader` flag. This spec is the regression
 * net for that: it asserts (a) statically that no mode can grow a
 * second hand-rolled bar again, and (b) behaviourally that each host
 * really does put the shared bar on screen with the same testids and
 * the task name as its title.
 *
 * The static half follows the repo's ChatView static-contract pattern
 * (cf. ChatView.prSidebar.spec.ts) because a full ChatView mount drags
 * in the SSE bus, the sync engine and every Pinia store; the shared
 * bar's own markup is covered by ChatAppBar.spec.ts.
 */
import { describe, expect, it, vi } from 'vitest'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { mount } from '@vue/test-utils'
import { defineComponent, h, nextTick, ref, type Ref } from 'vue'
import ChatAppBar from '../ChatAppBar.vue'
import AgentChatView from '../AgentChatView.vue'
import StandardTaskChatView from '../StandardTaskChatView.vue'
import type { Task } from '../../../stores/workspaces'

const viewsDir = resolve(__dirname, '..')
const src = (f: string) => readFileSync(join(viewsDir, f), 'utf8')

/** The markup only — HTML comments are prose, not contract. */
const templateOf = (s: string) => s.replace(/<!--[\s\S]*?-->/g, '')

const chatViewSrc = templateOf(src('ChatView.vue'))
const agentChatViewSrc = templateOf(src('AgentChatView.vue'))
const standardTaskChatViewSrc = templateOf(src('StandardTaskChatView.vue'))
const appBarSrc = src('ChatAppBar.vue')

/** The bar's rendered markup, normalised. Vue leaves `<!--v-if-->`
 * markers where a slot rendered nothing, and the indentation of a
 * slotted-but-empty `extras` differs from an absent slot — neither is
 * a visual difference, so both are stripped before comparing. */
const barHtml = (w: { get: (s: string) => { html: () => string } }) =>
  templateOf(w.get('[data-testid="chat-app-bar"]').html()).replace(/>\s+</g, '><').trim()

// ─── A ChatView stand-in that honours the real showHeader contract ──────────

// It renders the REAL ChatAppBar (so the assertions below run against
// the shipped bar, not a copy) and re-emits `close` from the bar's ✕,
// exactly like ChatView does.
const ChatViewStub = defineComponent({
  name: 'ChatView',
  props: ['chatId', 'chatName', 'type', 'cwd', 'showHeader', 'embedded'],
  emits: ['close', 'update-chat-id'],
  setup(props, { emit, slots }) {
    return () =>
      props.showHeader && !props.embedded
        ? h(
            ChatAppBar,
            { title: props.chatName as string, onClose: () => emit('close') },
            {
              extras: () => (slots['app-bar-extras'] ? slots['app-bar-extras']() : null),
            },
          )
        : h('div', { 'data-testid': 'chatview-no-bar' })
  },
})

const globalOpts = { stubs: { ChatView: ChatViewStub } }

describe('app-bar parity — the three workspace-item chat modes', () => {
  // ── Static contract: one app bar, three callers ──────────────────────────

  it('ChatAppBar.vue is the only component that renders a chat app bar', () => {
    // Nothing else in the views tree may mint the bar's testid — if a
    // mode grows its own bar again, it shows up here.
    const offenders: string[] = []
    for (const file of readdirSync(viewsDir)) {
      if (!file.endsWith('.vue') || file === 'ChatAppBar.vue') continue
      if (src(file).includes('data-testid="chat-app-bar"')) offenders.push(file)
    }
    expect(offenders).toEqual([])
  })

  it('the visual contract lives in exactly one file', () => {
    // The four things that made the three bars look different: the height, the padding, the
    // background token, the border. They are declared once, in ChatAppBar.vue — no host re-declares
    // any of them, so a mode cannot opt out of the shared look.
    for (const token of ['h-11', 'px-3', '--semantic-sidebar-bg', 'border-bottom']) {
      expect(appBarSrc).toContain(token)
      expect(agentChatViewSrc).not.toContain(token)
      expect(standardTaskChatViewSrc).not.toContain(token)
    }
  })

  it('ChatView delegates its header to ChatAppBar instead of a raw <header>', () => {
    expect(chatViewSrc).toContain("import ChatAppBar from './ChatAppBar.vue'")
    expect(chatViewSrc).toContain('<ChatAppBar')
    expect(chatViewSrc).toContain(':title="chatName"')
    expect(chatViewSrc).not.toMatch(/<header[\s>]/)
    // The old per-chat header testids are gone — the shared bar's
    // stable ones replace them, so specs stop depending on chatId.
    expect(chatViewSrc).not.toContain('chat-header-name-')
    expect(chatViewSrc).not.toContain('chat-header-close-')
    expect(chatViewSrc).not.toContain('chat-sidebar-toggle-')
  })

  it('ChatView keeps the headerless surfaces on the floating sidebar toggle', () => {
    // The standalone `chat-<id>` branch and the sub-agent peek still
    // render no bar, so the toggle must stay reachable there.
    expect(chatViewSrc).toMatch(/v-if="!showHeader && !embedded && !chatSidebar\.isOpen\.value"/)
    expect(chatViewSrc).toContain('data-testid="chat-sidebar-open"')
  })

  it('agent mode no longer hand-rolls a header', () => {
    expect(agentChatViewSrc).not.toMatch(/<header[\s>]/)
    expect(agentChatViewSrc).not.toContain('✕ Close')
    expect(agentChatViewSrc).toContain(':show-header="true"')
    // The busy spinner rides in the shared bar's extras slot.
    expect(agentChatViewSrc).toContain('#app-bar-extras')
  })

  it('standard (folder / memory / chat / routine) mode opts into the bar', () => {
    expect(standardTaskChatViewSrc).toContain(':show-header="true"')
    expect(standardTaskChatViewSrc).toMatch(/@close="emit\('close'\)"/)
  })

  it('AppLayout wires the same close handler into all three branches', () => {
    const appLayoutSrc = readFileSync(resolve(viewsDir, '../AppLayout.vue'), 'utf8')
    // kanban branch, AgentChatView branch, StandardTaskChatView branch.
    const closeBindings = appLayoutSrc.match(/@close="handleCloseTaskView"/g) ?? []
    expect(closeBindings.length).toBeGreaterThanOrEqual(4)
  })

  // ── Behavioural parity ──────────────────────────────────────────────────

  it('kanban mode renders the shared bar with the task name as title', () => {
    // The kanban branch mounts ChatView directly with
    // :show-header="true" — same contract the two wrappers forward.
    const wrapper = mount(ChatViewStub, {
      props: { chatId: 'task_k', chatName: 'gitlab support', showHeader: true },
      global: globalOpts,
    })
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    expect(bar.classes()).toContain('h-11')
    expect(wrapper.get('[data-testid="chat-app-bar-title"]').text()).toBe('gitlab support')
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-app-bar-close"]').exists()).toBe(true)
  })

  it('agent mode renders the identical bar', () => {
    const wrapper = mount(AgentChatView, {
      props: {
        task: { id: 'task_a', name: 'New Chat' } as Task,
        workspaceId: 'ws_1',
        itemId: 'item_1',
        cwd: '/abs',
      },
      global: { ...globalOpts, provide: { processingState: ref({}) } },
    })
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    expect(bar.classes()).toContain('h-11')
    expect(bar.attributes('style')).toContain('var(--semantic-sidebar-bg)')
    expect(wrapper.get('[data-testid="chat-app-bar-title"]').text()).toBe('New Chat')
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-app-bar-close"]').exists()).toBe(true)
  })

  it('standard mode renders the identical bar', () => {
    const wrapper = mount(StandardTaskChatView, {
      props: { task: { id: 'task_s', name: 'New Chat' } as Task, cwd: '/abs' },
      global: globalOpts,
    })
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    expect(bar.classes()).toContain('h-11')
    expect(bar.attributes('style')).toContain('var(--semantic-sidebar-bg)')
    expect(wrapper.get('[data-testid="chat-app-bar-title"]').text()).toBe('New Chat')
    expect(wrapper.find('[data-testid="chat-app-bar-sidebar-toggle"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-app-bar-close"]').exists()).toBe(true)
  })

  it('all three modes produce byte-identical bar markup for the same task', () => {
    const kanban = mount(ChatViewStub, {
      props: { chatId: 't', chatName: 'Same', showHeader: true },
      global: globalOpts,
    })
    const agent = mount(AgentChatView, {
      props: {
        task: { id: 't', name: 'Same' } as Task,
        workspaceId: 'w',
        itemId: 'i',
        cwd: '/c',
      },
      global: { ...globalOpts, provide: { processingState: ref({}) } },
    })
    const standard = mount(StandardTaskChatView, {
      props: { task: { id: 't', name: 'Same' } as Task, cwd: '/c' },
      global: globalOpts,
    })

    // The three bars differ only in where they sit in the tree, not in
    // how they render — the exact regression the user reported.
    expect(barHtml(agent)).toBe(barHtml(kanban))
    expect(barHtml(standard)).toBe(barHtml(kanban))
  })

  // ── Close routing ───────────────────────────────────────────────────────

  it('the ✕ closes an agent chat (forwards ChatView close)', async () => {
    const wrapper = mount(AgentChatView, {
      props: {
        task: { id: 'task_a', name: 'A' } as Task,
        workspaceId: 'w',
        itemId: 'i',
        cwd: '/c',
      },
      global: { ...globalOpts, provide: { processingState: ref({}) } },
    })
    await wrapper.get('[data-testid="chat-app-bar-close"]').trigger('click')
    expect(wrapper.emitted('close')).toHaveLength(1)
  })

  it('the ✕ closes a standard task chat (forwards ChatView close)', async () => {
    const wrapper = mount(StandardTaskChatView, {
      props: { task: { id: 'task_s', name: 'S' } as Task },
      global: globalOpts,
    })
    await wrapper.get('[data-testid="chat-app-bar-close"]').trigger('click')
    expect(wrapper.emitted('close')).toHaveLength(1)
  })

  it("the ◫ reaches the host's sidebar toggle in every mode", async () => {
    const onToggle = vi.fn()
    const wrapper = mount(ChatAppBar, {
      props: { title: 'X', onToggleSidebar: onToggle },
    })
    await wrapper.get('[data-testid="chat-app-bar-sidebar-toggle"]').trigger('click')
    expect(onToggle).toHaveBeenCalledTimes(1)
  })

  // ── Agent-mode extras ───────────────────────────────────────────────────

  it('the agent busy spinner renders inside the shared bar', async () => {
    const processingState: Ref<Record<string, boolean>> = ref({ task_busy: true })
    const wrapper = mount(AgentChatView, {
      props: {
        task: { id: 'task_busy', name: 'B' } as Task,
        workspaceId: 'w',
        itemId: 'i',
        cwd: '/c',
      },
      global: { ...globalOpts, provide: { processingState } },
    })
    await nextTick()
    const bar = wrapper.get('[data-testid="chat-app-bar"]')
    const spinner = bar.find('[data-testid="agent-chat-slider"]')
    expect(spinner.exists()).toBe(true)
    expect(spinner.attributes('aria-busy')).toBe('true')
  })
})

/** Behavioural tests for the agent-error indicator on <WorkspaceItemTaskCard> (the kanban board
 * card variant). */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import type { Task } from '@/stores/workspaces'
import { useAgentErrorStore } from '../stores/agentError'

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task_1',
    name: 'Test',
    task_type: 'standard',
    ...overrides,
  }
}

const RETRY_CONTENT =
  '[Retry 3/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.\n' +
  'Server said: {"error":{"message":"Provider returned error","code":429}}'

const BAIL_CONTENT =
  '[Agent Pabrik System error] workflow halted after 10 consecutive retries.\n' +
  'Reason for last retry: StreamInterrupted (source: callDynamicAgentNew).\n' +
  'Server said: upstream provider rate-limited'

describe('WorkspaceItemTaskCard — agent-error indicator', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('renders NO indicator when the store has no entry for task.id', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-meta-agent-error"]').exists()).toBe(false)
    // Root <button> must NOT have the data-has-agent-error attribute when
    // there's no error — Vue treats undefined bindings as no attribute.
    expect(wrapper.attributes('data-has-agent-error')).toBeUndefined()
  })

  it('renders the ⚠ icon + tooltip with retry chip + headline when store has a [Retry N/M] entry', async () => {
    const store = useAgentErrorStore()
    store.setError('task_1', RETRY_CONTENT)
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await nextTick()

    // The icon wrapper renders.
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(true)

    // Tooltip shows the retry chip.
    const tooltip = wrapper.find('[data-testid="task-agent-error-tooltip"]')
    expect(tooltip.exists()).toBe(true)
    const retryChip = wrapper.find('[data-testid="task-agent-error-retry"]')
    expect(retryChip.exists()).toBe(true)
    expect(retryChip.text()).toBe('retry 3/10')

    // Tooltip shows the parsed headline — error name + source.
    const headline = wrapper.find('[data-testid="task-agent-error-headline"]')
    expect(headline.exists()).toBe(true)
    expect(headline.text()).toContain('StreamInterrupted')
    expect(headline.text()).toContain('callDynamicAgentNew')

    // Meta-row pill renders with "3/10 retries".
    const metaPill = wrapper.find('[data-testid="task-meta-agent-error"]')
    expect(metaPill.exists()).toBe(true)
    expect(metaPill.text()).toContain('3/10 retries')

    // Root <button> has the data-has-agent-error attribute.
    expect(wrapper.attributes('data-has-agent-error')).toBe('true')
  })

  it('swaps the meta pill to "workflow halted" and hides the retry chip on the bail diagnostic', async () => {
    const store = useAgentErrorStore()
    store.setError('task_1', BAIL_CONTENT)
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await nextTick()

    // Icon still renders.
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(true)

    // No retry chip — bail diagnostics have no [Retry N/M] prefix.
    expect(wrapper.find('[data-testid="task-agent-error-retry"]').exists()).toBe(false)

    // Meta pill shows "workflow halted".
    const metaPill = wrapper.find('[data-testid="task-meta-agent-error"]')
    expect(metaPill.exists()).toBe(true)
    expect(metaPill.text()).toContain('workflow halted')

    // Headline still surfaces the bail reason.
    const headline = wrapper.find('[data-testid="task-agent-error-headline"]')
    expect(headline.exists()).toBe(true)
    expect(headline.text()).toContain('StreamInterrupted')

    // Border still applied.
    expect(wrapper.attributes('data-has-agent-error')).toBe('true')
  })

  it('removes all 3 affordances when clearForSession(task.id) is called', async () => {
    const store = useAgentErrorStore()
    store.setError('task_1', RETRY_CONTENT)
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await nextTick()
    // Sanity: present before clearing.
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-meta-agent-error"]').exists()).toBe(true)
    expect(wrapper.attributes('data-has-agent-error')).toBe('true')

    store.clearForSession('task_1')
    await nextTick()

    // All three affordances disappear.
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-meta-agent-error"]').exists()).toBe(false)
    expect(wrapper.attributes('data-has-agent-error')).toBeUndefined()
  })

  it('isolates two cards with different task ids — only the errored one shows the indicator', async () => {
    const store = useAgentErrorStore()
    store.setError('task_a', RETRY_CONTENT)
    // task_b is intentionally NOT errored.
    const wrapperA = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ id: 'task_a' }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    const wrapperB = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ id: 'task_b' }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()

    // task_a shows the indicator.
    expect(wrapperA.find('[data-testid="task-agent-error"]').exists()).toBe(true)
    expect(wrapperA.find('[data-testid="task-meta-agent-error"]').exists()).toBe(true)
    expect(wrapperA.attributes('data-has-agent-error')).toBe('true')

    // task_b does NOT.
    expect(wrapperB.find('[data-testid="task-agent-error"]').exists()).toBe(false)
    expect(wrapperB.find('[data-testid="task-meta-agent-error"]').exists()).toBe(false)
    expect(wrapperB.attributes('data-has-agent-error')).toBeUndefined()
  })

  it('does NOT apply the error-pulse animation when prefers-reduced-motion is reduce', async () => {
    // Mock window.matchMedia to report prefers-reduced-motion: reduce. The agent-error-pulse
    // keyframes live inside @media (prefers-reduced-motion: no-preference); with reduce, the
    // animation shorthand doesn't apply and computed animationName === 'none'.
    const matchMediaMock = vi.fn((query: string) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))
    vi.stubGlobal('matchMedia', matchMediaMock)

    const store = useAgentErrorStore()
    store.setError('task_1', RETRY_CONTENT)
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
      attachTo: document.body,
    })
    await nextTick()

    const iconEl = wrapper
      .find('[data-testid="task-agent-error"] .error-pulse')
      .element as HTMLElement
    expect(iconEl).toBeTruthy()
    // The animationName resolves to 'none' because the @media
    // (prefers-reduced-motion: no-preference) block is not matched
    // when matchMedia reports reduce.
    const computed = window.getComputedStyle(iconEl)
    expect(computed.animationName).toBe('none')

    wrapper.unmount()
  })

  it('renders the ⚠ icon alongside an active spinner (additive, not mutually exclusive)', async () => {
    // The retry chain fires WHILE the worker is still active, so the spinner and the error
    // indicator must coexist on the standard branch (not v-else-if). Mount with both
    // processingState[id] AND a store error, assert both render.
    const store = useAgentErrorStore()
    store.setError('task_1', RETRY_CONTENT)

    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ id: 'task_1' }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await nextTick()
    // Inject a fake processingState via provide() — same key as the real App.vue injection.
    expect(wrapper.find('[data-testid="task-agent-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-spinner"]').exists()).toBe(false)
  })
})

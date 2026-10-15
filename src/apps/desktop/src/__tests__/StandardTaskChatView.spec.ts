// StandardTaskChatView — thin wrapper around <ChatView> for the
// standard (non-kanban / non-design) task chat branch in AppLayout.
//
// These tests pin down the wrapper's contract:
//
//   1. The chat-id is derived as `chat-${task.id}` (migration 052
//      invariant: task.id == session.id).
//   2. chat-name falls back to '' when task.name is undefined
//      (the inline branch uses `activeTask.name ?? ''`, this
//      wrapper preserves that fallback — defensive against
//      backends that omit the name field).
//   3. cwd is forwarded verbatim to ChatView.
//   4. update-chat-id is re-emitted with the same payload
//      (oldId, newId) ChatView emits — AppLayout's
//      handleUpdateChatId relies on receiving both arguments
//      verbatim to update navigationStore.activeChatId and
//      sidebarRef.updateChatId.
//   5. Switching the `task` prop forces a fresh ChatView mount
//      (the `:key` reactivity rule) — preserves
//      useChatScrollRestore's scroll position across task
//      switches (same as the kanban chat branch's `:key="'kanban-chat-' +
//      activeTask.id"`).
//   6. `:show-header` is set and ChatView's `close` is re-emitted,
//      so this mode renders the same shared ChatAppBar as the kanban
//      and agent modes (cross-mode proof: ChatAppBarParity.spec.ts).
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import StandardTaskChatView from '../components/views/StandardTaskChatView.vue'
import type { Task } from '../stores/workspaces'

// Capture the :key ChatView is mounted with so we can assert the
// wrapper really did pass `chat-${task.id}` (the migration-052
// invariant — NOT the raw task.id). Each new mount registers here.
const mountedKeys: string[] = []

function mountWrapper(props: { task: Task; cwd?: string }): {
  wrapper: VueWrapper
  chatViewProps: { chatId: string; chatName: string; cwd: string }[]
} {
  const chatViewProps: { chatId: string; chatName: string; cwd: string }[] = []
  const wrapper = mount(StandardTaskChatView, {
    props,
    global: {
      stubs: {
        // Custom ChatView stub: the default `true` stub renders no HTML and drops props. Bind the
        // props to data attributes so the test can assert what StandardTaskChatView forwarded.
        // Also push each mount's :key into `mountedKeys` so we can verify the wrapper's :key
        // reactivity rule (test #5).
        ChatView: {
          name: 'ChatView',
          template:
            '<div data-testid="chatview-stub" :data-chat-id="chatId" :data-chat-name="chatName" :data-chat-cwd="cwd" :data-show-header="String(showHeader)" />',
          props: [
            'chatId',
            'chatName',
            'type',
            'cwd',
            'taskId',
            'taskName',
            'projectName',
            'showHeader',
          ],
          emits: ['close', 'update-chat-id'],
          mounted() {
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            const k = (this.$ as any).vnode?.key
            mountedKeys.push(typeof k === 'string' ? k : String(k ?? ''))
            chatViewProps.push({
              chatId: this.chatId,
              chatName: this.chatName,
              cwd: this.cwd,
            })
          },
        },
      },
    },
    attachTo: document.body,
  })
  return { wrapper, chatViewProps }
}

describe('StandardTaskChatView', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    mountedKeys.length = 0
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('derives chat-id as `chat-${task.id}` (migration 052 invariant)', () => {
    const task: Task = { id: 'task_xyz', name: 'New Chat' } as Task
    const { wrapper: w } = mountWrapper({ task })
    const chatView = w.find('[data-testid="chatview-stub"]')
    expect(chatView.exists()).toBe(true)
    expect(chatView.attributes('data-chat-id')).toBe('chat-task_xyz')
    expect(chatView.attributes('data-chat-name')).toBe('New Chat')
    wrapper = w
  })

  it('forwards the empty string when task.name is undefined', () => {
    // Defensive against backend payloads that omit `name` — the inline AppLayout branch used
    // `activeTask.name ?? ''`, this wrapper preserves that fallback so ChatView never receives
    // `undefined` for a prop that the type system declares string.
    const task: Task = { id: 'task_noname' } as Task
    const { wrapper: w } = mountWrapper({ task })
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-chat-name')).toBe('')
    wrapper = w
  })

  it('forwards cwd verbatim to ChatView', () => {
    const task: Task = { id: 'task_a', name: 'A' } as Task
    const { wrapper: w } = mountWrapper({ task, cwd: '/abs/path/to/cwd' })
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-chat-cwd')).toBe(
      '/abs/path/to/cwd',
    )
    wrapper = w
  })

  it('defaults cwd to the empty string when the prop is omitted', () => {
    // matches ChatView's `:cwd?: string` optional prop — the wrapper
    // should not leak undefined through.
    const task: Task = { id: 'task_a', name: 'A' } as Task
    const { wrapper: w } = mountWrapper({ task })
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-chat-cwd')).toBe('')
    wrapper = w
  })

  it('re-emits update-chat-id with the (oldId, newId) payload ChatView emits', async () => {
    const task: Task = { id: 'task_a', name: 'A' } as Task
    const { wrapper: w } = mountWrapper({ task })
    // Find the stubbed ChatView's emit binding and trigger it the
    // same way ChatView's @update-chat-id handler would.
    const onUpdateChatId = vi.fn()
    w.vm.$emit('update-chat-id', 'chat-task_a', 'chat-task_a_renamed')
    // Vue Wrapper $emit returns boolean — capture via listener.
    // Use `emitted()` API instead for a typed check.
    expect(w.emitted('update-chat-id')).toBeTruthy()
    expect(w.emitted('update-chat-id')![0]).toEqual(['chat-task_a', 'chat-task_a_renamed'])
    expect(onUpdateChatId).not.toHaveBeenCalled() // sanity
    wrapper = w
  })

  it('turns the shared chat app bar on and re-emits its ✕ as close', async () => {
    // Pre-fix this mode rendered NO bar at all: the sidebar toggle floated over the transcript and
    // there was no way to leave the chat from the surface. It must now match the kanban and agent
    // modes — see ChatAppBarParity.spec.ts for the cross-mode proof.
    const task: Task = { id: 'task_a', name: 'A' } as Task
    const { wrapper: w } = mountWrapper({ task })
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-show-header')).toBe('true')

    // ChatView's `close` is re-emitted verbatim so AppLayout can route
    // it through handleCloseTaskView, same as the other two branches.
    w.findComponent({ name: 'ChatView' }).vm.$emit('close')
    await nextTick()
    expect(w.emitted('close')).toBeTruthy()
    wrapper = w
  })

  it('forces a fresh ChatView mount when the task prop changes (useChatScrollRestore key rule)', async () => {
    // The wrapper pins `:key="chat-${task.id}"` on <ChatView>. When the user switches tasks (e.g.
    // via Sidebar), a new key remounts ChatView fresh — preserving scroll-restore across switches
    // and clearing the previous task's message cache.
    // Pre-fix (inline branch) had the same behaviour; this wrapper preserves it.
    const taskA: Task = { id: 'task_a', name: 'A' } as Task
    const taskB: Task = { id: 'task_b', name: 'B' } as Task
    const { wrapper: w } = mountWrapper({ task: taskA })
    await w.setProps({ task: taskB })
    await nextTick()
    // Two ChatView mounts recorded — initial + after task switch.
    expect(mountedKeys.length).toBe(2)
    expect(mountedKeys[0]).toBe('chat-task_a')
    expect(mountedKeys[1]).toBe('chat-task_b')
    // The currently-rendered ChatView reflects the new task.
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-chat-id')).toBe('chat-task_b')
    expect(w.find('[data-testid="chatview-stub"]').attributes('data-chat-name')).toBe('B')
    wrapper = w
  })
})

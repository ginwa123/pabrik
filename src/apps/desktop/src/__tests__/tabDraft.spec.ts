import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import FileInput from '../components/file/FileInput.vue'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

/**  * Task 5 of the tab-mode plan: drafts must survive the remount that every tab switch performs
 * (AppLayout keys each view by the active tab), while `GitFileViewer`'s FileInput — which passes no
 * `draftKey` — must stay completely unwired. */

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_draft' }),
    writable: true,
    configurable: true,
  })
}

function mountInput(draftKey?: string) {
  return mount(FileInput, {
    props: draftKey ? { cwd: '', draftKey } : { cwd: '' },
    attachTo: document.body,
  })
}

describe('FileInput — draft survival across tab switches', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('restores the draft written by an earlier mount of the same chat', async () => {
    const tabs = useTabsStore()
    tabs.setDraft('chat:A', 'half typed')

    const wrapper = mountInput('chat:A')
    await nextTick()
    expect((wrapper.find('textarea').element as HTMLTextAreaElement).value).toBe('half typed')
    wrapper.unmount()
  })

  it('does not clobber a pre-filled message with an older draft', async () => {
    const tabs = useTabsStore()
    tabs.setDraft('chat:A', 'old draft')

    const wrapper = mount(FileInput, { props: { cwd: '', draftKey: 'chat:A', initialMessage: 'from the diff view' } })
    await nextTick()
    expect((wrapper.find('textarea').element as HTMLTextAreaElement).value).toBe('from the diff view')
    wrapper.unmount()
  })

  it('saves typed text after the debounce', async () => {
    vi.useFakeTimers()
    const tabs = useTabsStore()
    const wrapper = mountInput('chat:A')

    await wrapper.find('textarea').setValue('hello')
    expect(tabs.getDraft('chat:A')).toBe('')
    vi.advanceTimersByTime(250)
    expect(tabs.getDraft('chat:A')).toBe('hello')
    wrapper.unmount()
  })

  it('flushes a pending draft on unmount so a fast tab switch cannot lose it', async () => {
    vi.useFakeTimers()
    const tabs = useTabsStore()
    const wrapper = mountInput('chat:A')

    await wrapper.find('textarea').setValue('typed, then switched tabs')
    expect(tabs.getDraft('chat:A')).toBe('')

    wrapper.unmount() // beats the 200 ms debounce
    expect(tabs.getDraft('chat:A')).toBe('typed, then switched tabs')
  })

  it('clears the draft when the message is sent', async () => {
    const tabs = useTabsStore()
    tabs.setDraft('chat:A', 'send me')

    const wrapper = mountInput('chat:A')
    await nextTick()
    await wrapper.find('[data-testid="send-message-button"]').trigger('click')
    await nextTick()

    expect(wrapper.emitted('submit')).toBeTruthy()
    expect(tabs.getDraft('chat:A')).toBe('')
    expect((wrapper.find('textarea').element as HTMLTextAreaElement).value).toBe('')
    wrapper.unmount()
  })

  it('keeps two chats in separate buckets', async () => {
    const tabs = useTabsStore()
    const first = mountInput('chat:A')
    await first.find('textarea').setValue('for A')
    first.unmount()
    expect(tabs.getDraft('chat:A')).toBe('for A')

    const second = mountInput('chat:B')
    await second.find('textarea').setValue('for B')
    second.unmount()

    expect(tabs.getDraft('chat:A')).toBe('for A')
    expect(tabs.getDraft('chat:B')).toBe('for B')

    const backToA = mountInput('chat:A')
    await nextTick()
    expect((backToA.find('textarea').element as HTMLTextAreaElement).value).toBe('for A')
    backToA.unmount()
  })

  it('reads and writes nothing without a draftKey', async () => {
    vi.useFakeTimers()
    const tabs = useTabsStore()
    tabs.setDraft('chat:A', 'not mine')

    const wrapper = mountInput()
    await wrapper.find('textarea').setValue('no bucket here')
    vi.advanceTimersByTime(300)
    wrapper.unmount()

    expect(tabs.drafts).toEqual({ 'chat:A': 'not mine' })
  })
})

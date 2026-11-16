import { describe, expect, it, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { defineComponent, h } from 'vue'
import { useChatRightSidebar } from '../chat_right_sidebar/useChatRightSidebar'

// In-memory localStorage fallback for environments where jsdom was created without a url (localStorage undefined).
if (typeof localStorage === 'undefined') {
  const store = new Map<string, string>()
  ;(globalThis as unknown as { localStorage: Storage }).localStorage = {
    getItem: (k: string) => (store.has(k) ? store.get(k)! : null),
    setItem: (k: string, v: string) => void store.set(k, String(v)),
    removeItem: (k: string) => void store.delete(k),
    clear: () => store.clear(),
    key: (i: number) => [...store.keys()][i] ?? null,
    get length() {
      return store.size
    },
  } as Storage
}

function mountComposable(chatType = 'chat') {
  let exposed: ReturnType<typeof useChatRightSidebar> | null = null
  const Host = defineComponent({
    setup() {
      exposed = useChatRightSidebar(chatType)
      return () => h('div')
    },
  })
  const wrapper = mount(Host, { attachTo: document.body })
  return {
    wrapper,
    get exposed() {
      return exposed!
    },
  }
}

describe('useChatRightSidebar', () => {
  beforeEach(() => {
    try {
      localStorage.clear()
    } catch {
      // jsdom without url — localStorage unavailable; composable already guards with try/catch so tests still exercise logic.
    }
  })

  it('defaults to closed with default width', () => {
    const { wrapper, exposed } = mountComposable()
    expect(exposed.isOpen.value).toBe(false)
    expect(exposed.width.value).toBe(280)
    wrapper.unmount()
  })

  it('toggles open state and persists per chat type', () => {
    const { wrapper, exposed } = mountComposable('task')
    exposed.toggle()
    expect(exposed.isOpen.value).toBe(true)
    expect(localStorage.getItem('pabrik-chat-right-sidebar-open:task')).toBe('true')
    exposed.toggle()
    expect(exposed.isOpen.value).toBe(false)
    wrapper.unmount()
  })

  it('clamps width to min/max and persists', () => {
    const { wrapper, exposed } = mountComposable()
    exposed.setWidth(50)
    expect(exposed.width.value).toBe(200)
    exposed.setWidth(2000)
    expect(exposed.width.value).toBe(600)
    exposed.setWidth(360)
    expect(exposed.width.value).toBe(360)
    expect(localStorage.getItem('pabrik-right-sidebar-width')).toBe('360')
    wrapper.unmount()
  })

  it('tracks selected file', () => {
    const { wrapper, exposed } = mountComposable()
    expect(exposed.selectedFile.value).toBeNull()
    exposed.selectFile('a.txt', false)
    expect(exposed.selectedFile.value).toEqual({ path: 'a.txt', staged: false })
    exposed.clearSelection()
    expect(exposed.selectedFile.value).toBeNull()
    wrapper.unmount()
  })

  it('toggles on Cmd+B', () => {
    const { wrapper, exposed } = mountComposable()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'b', metaKey: true, bubbles: true }))
    expect(exposed.isOpen.value).toBe(true)
    wrapper.unmount()
  })
})

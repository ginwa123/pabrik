import { describe, it, expect } from 'vitest'
import { defineComponent, h, ref } from 'vue'
import { mount } from '@vue/test-utils'
import { useMobileDrawer } from '../components/appLayout/useMobileDrawer'

function makeDrawerHost(startOpen = true) {
  const open = ref(startOpen)
  const navigations = new Set<() => void>()

  const Host = defineComponent({
    setup() {
      useMobileDrawer({
        host: {
          isOpen: () => open.value,
          close: () => {
            open.value = false
          },
        },
        route: {
          onNavigate: (cb) => {
            navigations.add(cb)
            return () => {
              navigations.delete(cb)
            }
          },
        },
      })
      return () => h('span', open.value ? 'open' : 'closed')
    },
  })

  return { Host, open, navigations }
}

const pressEscape = () => {
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
}

describe('useMobileDrawer', () => {
  it('closes an open drawer when Escape is pressed', async () => {
    const { Host } = makeDrawerHost()
    const wrapper = mount(Host)
    pressEscape()
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('closed')
    wrapper.unmount()
  })

  it('leaves a closed drawer closed when Escape is pressed', async () => {
    const { Host } = makeDrawerHost(false)
    const wrapper = mount(Host)
    pressEscape()
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('closed')
    wrapper.unmount()
  })

  it('ignores keys other than Escape', async () => {
    const { Host } = makeDrawerHost()
    const wrapper = mount(Host)
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }))
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('open')
    wrapper.unmount()
  })

  it('closes the drawer when the route changes', async () => {
    const { Host, navigations } = makeDrawerHost()
    const wrapper = mount(Host)
    for (const navigate of navigations) navigate()
    await wrapper.vm.$nextTick()
    expect(wrapper.text()).toBe('closed')
    wrapper.unmount()
  })

  it('stops closing on Escape once it unmounts', () => {
    const { Host, open } = makeDrawerHost()
    const wrapper = mount(Host)
    wrapper.unmount()
    pressEscape()
    expect(open.value).toBe(true)
  })

  it('releases the route subscription when it unmounts', () => {
    const { Host, navigations } = makeDrawerHost()
    const wrapper = mount(Host)
    expect(navigations.size).toBe(1)
    wrapper.unmount()
    expect(navigations.size).toBe(0)
  })
})

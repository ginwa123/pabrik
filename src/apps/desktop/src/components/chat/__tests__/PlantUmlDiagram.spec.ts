/** Behavioural tests for <PlantUmlDiagram>. Nothing here touches the network: the component's
 * contract is "show the URL the server would answer, or the source when it refuses". */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import PlantUmlDiagram from '../PlantUmlDiagram.vue'
import { plantumlSvgUrl } from '../../../helpers/plantuml'

const SOURCE = '@startuml\nAlice -> Bob: hello\n@enduml'

const mountDiagram = (source: string) => mount(PlantUmlDiagram, { props: { source } })

beforeEach(() => {
  Object.assign(navigator, {
    clipboard: { writeText: vi.fn().mockResolvedValue(undefined) },
  })
})

describe('PlantUmlDiagram', () => {
  it('points an <img> at the PlantUML svg URL for the block source', () => {
    const wrapper = mountDiagram(SOURCE)
    const img = wrapper.find('[data-testid="chat-plantuml-img"]')
    expect(img.exists()).toBe(true)
    expect(img.attributes('src')).toBe(plantumlSvgUrl(SOURCE))
  })

  it('links the diagram out so it can be enlarged without a lightbox', () => {
    const wrapper = mountDiagram(SOURCE)
    const link = wrapper.find('[data-testid="chat-plantuml-open"]')
    expect(link.attributes('href')).toBe(plantumlSvgUrl(SOURCE))
    expect(link.attributes('target')).toBe('_blank')
    expect(link.attributes('rel')).toContain('noopener')
  })

  it('keeps the image out of the flow until the server has answered', async () => {
    const wrapper = mountDiagram(SOURCE)
    const img = wrapper.find('[data-testid="chat-plantuml-img"]')
    expect(img.classes()).not.toContain('chat-plantuml-img--ready')
    await img.trigger('load')
    expect(img.classes()).toContain('chat-plantuml-img--ready')
  })

  it('falls back to the source, and names the host, when the render fails', async () => {
    const wrapper = mountDiagram(SOURCE)
    await wrapper.find('[data-testid="chat-plantuml-img"]').trigger('error')
    const note = wrapper.find('[data-testid="chat-plantuml-error"]')
    expect(note.exists()).toBe(true)
    expect(note.text()).toContain('www.plantuml.com')
    expect(wrapper.text()).toContain('Alice -> Bob: hello')
    expect(wrapper.find('[data-testid="chat-plantuml-img"]').exists()).toBe(false)
  })

  it('retries the image when the source changes', async () => {
    const wrapper = mountDiagram(SOURCE)
    await wrapper.find('[data-testid="chat-plantuml-img"]').trigger('error')
    expect(wrapper.find('[data-testid="chat-plantuml-error"]').exists()).toBe(true)
    await wrapper.setProps({ source: '@startuml\nA -> B\n@enduml' })
    expect(wrapper.find('[data-testid="chat-plantuml-img"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-plantuml-error"]').exists()).toBe(false)
  })

  it('copies the source, not the encoded URL', async () => {
    const wrapper = mountDiagram(SOURCE)
    await wrapper.find('[data-testid="chat-plantuml-copy"]').trigger('click')
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(SOURCE)
  })
})

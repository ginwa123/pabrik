/** Behavioural mount tests for DesignElementPreview.vue. The component renders a sandboxed iframe
 * for the element's HTML body. When `editable=true`, the iframe body becomes contenteditable and
 * emits `htmlChanged` on blur. */
/** Fill contract (2026-07-29, fix for "white in corner" bug): the iframe's `background` style is
 * bound to `props.fill`, NOT a hardcoded 'white'. */
/** When `fill` is empty (or unset), the iframe background is 'transparent' so the parent wrapper's
 * `backgroundColor: element.fill` shows through. */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'

import DesignElementPreview from '../components/design/DesignElementPreview.vue'

// ─── Behavioural mount tests (2026-07-29 — fill-aware iframe bg) ──────────

function mountPreview(props: { html: string; fill?: string; pointerEvents?: 'auto' | 'none' }): VueWrapper {
  return mount(DesignElementPreview, {
    props: {
      html: props.html,
      fill: props.fill,
      pointerEvents: props.pointerEvents ?? 'auto',
    },
  })
}

describe('DesignElementPreview.vue — iframe background follows fill prop', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // No store needed; DesignElementPreview is pure props-only.
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  // Regression for the "white in corner" bug: pre-fix the iframe's inline style was `background:
  // 'white'` regardless of the element's fill.
  // For elements with empty / transparent fills (input fields, buttons, modal backdrop with empty
  // HTML), the canvas rendered as small white rectangles. Post-fix (this test): the iframe
  // background inherits the element's `fill` prop.
  // Empty fill → 'transparent' → the parent wrapper's fill shows through.
  it('sets the iframe background to transparent when fill is empty', () => {
    wrapper = mountPreview({ html: '<div>x</div>', fill: '' })
    const iframe = wrapper.find('[data-testid="design-element-preview"]')
    expect(iframe.exists()).toBe(true)
    // jsdom normalizes no-bg / transparent to empty string in style;
    // assert the absence of any white-ish background.
    const styleAttr = iframe.attributes('style') ?? ''
    expect(styleAttr).not.toContain('background: white')
    expect(styleAttr).not.toContain('background-color: white')
    expect(styleAttr).not.toMatch(/background:\s*rgb\(255,\s*255,\s*255\)/)
  })

  it('sets the iframe background to the fill color when fill is provided', () => {
    wrapper = mountPreview({
      html: '<div>x</div>',
      fill: 'rgba(15, 14, 13, 0.78)',
    })
    const iframe = wrapper.find('[data-testid="design-element-preview"]')
    const styleAttr = iframe.attributes('style') ?? ''
    // The fill propagates into the iframe's inline style attribute.
    expect(styleAttr).toContain('rgba(15, 14, 13, 0.78)')
  })

  it('updates the iframe background reactively when fill changes', async () => {
    wrapper = mountPreview({ html: '<div>x</div>', fill: '#ffffff' })
    const iframe = wrapper.find('[data-testid="design-element-preview"]')
    expect(iframe.attributes('style') ?? '').toContain('rgb(255, 255, 255)')

    await wrapper.setProps({ fill: 'rgba(0, 0, 0, 0.5)' })
    await nextTick()
    const updatedStyle = iframe.attributes('style') ?? ''
    expect(updatedStyle).toContain('rgba(0, 0, 0, 0.5)')
    // Old white should not still be present.
    expect(updatedStyle).not.toContain('rgb(255, 255, 255)')
  })

  it('still sets iframe background to transparent (NOT white) by default', () => {
    // No fill prop at all — default value is '' → transparent.
    wrapper = mount(DesignElementPreview, {
      props: { html: '<div>x</div>' },
    })
    const iframe = wrapper.find('[data-testid="design-element-preview"]')
    const styleAttr = iframe.attributes('style') ?? ''
    expect(styleAttr).not.toContain('background: white')
    expect(styleAttr).not.toContain('rgb(255, 255, 255)')
  })
})
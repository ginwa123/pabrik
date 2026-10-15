/** Tests for ToolParameters.vue — shared Arguments block for tool-output cards.
 * Guard (mirrors McpTool.vue hasArgs): trim in '', '{}' -> render nothing.
 * Else render <details><summary>Arguments</summary><pre>{{pretty}}</pre></details>.
 * pretty: try JSON.parse -> stringify null,2 else raw string (XML displays raw). */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import ToolParameters from './ToolParameters.vue'

describe('ToolParameters', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders nothing when parameters is undefined', () => {
    wrapper = mount(ToolParameters, { props: {} })
    expect(wrapper.find('details').exists()).toBe(false)
    expect(wrapper.text()).toBe('')
  })

  it('renders nothing for empty string', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '' } })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('renders nothing for whitespace-only string', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '   \n  ' } })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('renders nothing for empty JSON object', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '{}' } })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('renders nothing for padded empty JSON object', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '  {}  ' } })
    expect(wrapper.find('details').exists()).toBe(false)
  })

  it('renders XML params as a block with raw content', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '<path>/foo</path>' } })
    const details = wrapper.find('details')
    expect(details.exists()).toBe(true)
    expect(details.find('summary').text()).toBe('Arguments')
    expect(details.find('pre').text()).toContain('<path>/foo</path>')
  })

  it('renders JSON params as pretty JSON', () => {
    wrapper = mount(ToolParameters, { props: { parameters: '{"path":"/foo"}' } })
    const details = wrapper.find('details')
    expect(details.exists()).toBe(true)
    expect(details.find('summary').text()).toBe('Arguments')
    expect(details.find('pre').text()).toContain('"path": "/foo"')
  })

  it('falls back to raw string for malformed input', () => {
    const raw = 'not json {{{ <path>/foo'
    wrapper = mount(ToolParameters, { props: { parameters: raw } })
    const details = wrapper.find('details')
    expect(details.exists()).toBe(true)
    expect(details.find('pre').text()).toContain(raw)
  })
})

import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PabrikSaveStatus from '../components/pabrik/PabrikSaveStatus.vue'

function mountStatus(state: 'idle' | 'saving' | 'saved' | 'error', message = '') {
  return mount(PabrikSaveStatus, { props: { state, message } })
}

describe('PabrikSaveStatus', () => {
  it('renders nothing while no change is on its way to the server', () => {
    expect(mountStatus('idle').find('[data-testid="save-status"]').exists()).toBe(false)
  })

  it('says Saving… while the PUT is in flight', () => {
    const wrapper = mountStatus('saving')
    expect(wrapper.find('[data-testid="save-status"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="save-status-text"]').text()).toBe('Saving…')
  })

  it('says Saved once the server has the change', () => {
    expect(mountStatus('saved').find('[data-testid="save-status-text"]').text()).toBe('Saved')
  })

  it('shows the failure reason so a rejected change never looks saved', () => {
    const text = mountStatus('error', 'HTTP 500').find('[data-testid="save-status-text"]').text()
    expect(text).toContain("Couldn't save")
    expect(text).toContain('HTTP 500')
  })

  it('offers no controls: the change needs no confirmation from the user', () => {
    expect(mountStatus('saved').findAll('button')).toHaveLength(0)
  })

  it('sits at the top of the pane with the separator on its bottom edge', () => {
    const strip = mountStatus('saving').find('[data-testid="save-status"]')
    expect(strip.classes()).toContain('sticky')
    expect(strip.classes()).toContain('top-0')
    expect(strip.classes()).toContain('border-b')
    expect(strip.classes()).not.toContain('border-t')
  })
})

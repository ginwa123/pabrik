/** Tests for PabrikGeneralSection.vue — the General tab in USER settings. Retry backoff is a
 * workspace value and is covered by PabrikRuntimeSection.spec.ts. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import PabrikGeneralSection, {
  type PabrikGeneralSettings,
} from '../components/pabrik/PabrikGeneralSection.vue'

const DEFAULT_SETTINGS: PabrikGeneralSettings = {
  notify_on_complete: false,
  notify_on_error: false,
  // Plan 2026-09-10-web-launch-toggle: 4th key (browser-mode flag).
  web_launch_enabled: false,
  chat_view: 'dev',
}

describe('PabrikGeneralSection', () => {
  it('renders the notification toggles and the chat-view control', () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS } },
    })
    expect(wrapper.find('[data-testid="toggle-notify-on-complete"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="toggle-notify-on-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-view-dev"]').exists()).toBe(true)
    // Human-readable copy.
    expect(wrapper.text()).toContain('Notify when agent finishes')
    expect(wrapper.text()).toContain('Notify when agent fails')
  })

  it('offers no retry-delay input — that setting lives in workspace settings', () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS } },
    })
    expect(wrapper.find('[data-testid="input-retry-delay-seconds"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="retry-delay-ms-readout"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('Retry delay')
  })

  it('reflects the loaded settings in the toggles', () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: true,
          web_launch_enabled: true,
          chat_view: 'dev',
        },
        webUrl: 'http://127.0.0.1:51234/',
      },
    })
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-complete"]').element as HTMLInputElement)
        .checked,
    ).toBe(true)
    expect(
      (wrapper.find('[data-testid="toggle-notify-on-error"]').element as HTMLInputElement).checked,
    ).toBe(true)
  })

  it('clicking notify_on_complete emits update:modelValue with the flipped boolean', async () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS, notify_on_complete: false } },
    })
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    expect(wrapper.emitted('update:modelValue')?.[0]?.[0]).toEqual({
      notify_on_complete: true,
      notify_on_error: false,
      web_launch_enabled: false,
      chat_view: 'dev',
    })
  })

  it('clicking notify_on_error emits update:modelValue with the flipped boolean (independent from complete)', async () => {
    // Lock the contract that the two toggles are independent — toggling
    // notify_on_error MUST NOT silently flip notify_on_complete.
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: false,
          web_launch_enabled: false,
          chat_view: 'dev',
        },
      },
    })
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as PabrikGeneralSettings
    expect(emitted.notify_on_error).toBe(true)
    expect(emitted.notify_on_complete).toBe(true)
  })

  it('toggling a control does not lose the OTHER settings (whole-object emit)', async () => {
    // The component emits the FULL settings object on each change
    // (not a partial patch). Lock that contract so the parent's
    // v-model never drops a sibling field.
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: false,
          web_launch_enabled: false,
          chat_view: 'dev',
        },
      },
    })
    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    const emitted = wrapper.emitted('update:modelValue')?.[0]?.[0] as PabrikGeneralSettings
    expect(emitted).toEqual({
      notify_on_complete: true,
      notify_on_error: true,
      web_launch_enabled: false,
      chat_view: 'dev',
    })
  })

  // Plan 2026-09-10-web-launch-toggle: browser-mode toggle + URL pill.
  it('renders the web-launch toggle and hides the URL pill when OFF', () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: { modelValue: { ...DEFAULT_SETTINGS, web_launch_enabled: false } },
    })
    expect(wrapper.find('[data-testid="toggle-web-launch"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('Launch web (browser mode)')
    expect(wrapper.find('[data-testid="pill-web-url-row"]').exists()).toBe(false)
  })

  it('clicking web_launch_enabled emits update:modelValue preserving siblings', async () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: {
          notify_on_complete: true,
          notify_on_error: false,
          web_launch_enabled: false,
          chat_view: 'dev',
        },
      },
    })
    await wrapper.find('[data-testid="toggle-web-launch"]').setValue(true)
    expect(wrapper.emitted('update:modelValue')?.[0]?.[0]).toEqual({
      notify_on_complete: true,
      notify_on_error: false,
      web_launch_enabled: true,
      chat_view: 'dev',
    })
  })

  it('shows the URL pill with Open/Copy when ON and a webUrl is provided', async () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: { ...DEFAULT_SETTINGS, web_launch_enabled: true },
        webUrl: 'http://127.0.0.1:51234/',
      },
    })
    expect(wrapper.find('[data-testid="pill-web-url-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pill-web-url"]').text()).toContain('http://127.0.0.1:51234/')
    const openBtn = wrapper.find('[data-testid="btn-open-web"]')
    const copyBtn = wrapper.find('[data-testid="btn-copy-web"]')
    expect((openBtn.element as HTMLButtonElement).disabled).toBe(false)
    expect((copyBtn.element as HTMLButtonElement).disabled).toBe(false)
    await openBtn.trigger('click')
    await copyBtn.trigger('click')
    expect(wrapper.emitted('open-web')).toBeTruthy()
    expect(wrapper.emitted('copy-web')).toBeTruthy()
  })

  it('disables Open/Copy and shows a waiting hint when ON but webUrl is unknown', () => {
    const wrapper = mount(PabrikGeneralSection, {
      props: {
        modelValue: { ...DEFAULT_SETTINGS, web_launch_enabled: true },
        // webUrl omitted → null default.
      },
    })
    expect(wrapper.find('[data-testid="pill-web-url-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="pill-web-url"]').text()).toContain(
      'Starting local web server',
    )
    expect(
      (wrapper.find('[data-testid="btn-open-web"]').element as HTMLButtonElement).disabled,
    ).toBe(true)
    expect(
      (wrapper.find('[data-testid="btn-copy-web"]').element as HTMLButtonElement).disabled,
    ).toBe(true)
  })
})

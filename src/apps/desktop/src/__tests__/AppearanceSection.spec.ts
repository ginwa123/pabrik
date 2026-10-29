import { beforeEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import AppearanceSection from '../components/settings/AppearanceSection.vue'
import { THEMES, THEME_STORAGE_KEY } from '../theme/themes'
import { makeLocalStorageStub } from './helpers'

const root = (): HTMLElement => document.documentElement

function mountSection(): VueWrapper {
  return mount(AppearanceSection, { attachTo: document.body })
}

async function openPicker(wrapper: VueWrapper): Promise<void> {
  await wrapper.get('[data-testid="theme-picker-trigger"]').trigger('click')
}

describe('AppearanceSection', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    wrapper?.unmount()
    wrapper = null
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    delete root().dataset.theme
  })

  it('shows the current theme on the trigger', () => {
    wrapper = mountSection()

    expect(wrapper.get('[data-testid="theme-picker-label"]').text()).toBe('Dark')
    expect(wrapper.find('[data-testid="theme-picker"]').exists()).toBe(false)
  })

  it('lists every theme the app ships once the picker is open', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    for (const theme of THEMES) {
      expect(wrapper.find(`[data-testid="theme-option-${theme.id}"]`).exists()).toBe(true)
    }
    expect(
      wrapper.get('[data-testid="theme-option-dark"]').attributes('aria-selected'),
    ).toBe('true')
  })

  it('repaints the app, remembers the choice and updates the trigger', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    await wrapper.get('[data-testid="theme-option-tokyo-night"]').trigger('click')

    expect(root().dataset.theme).toBe('tokyo-night')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('tokyo-night')
    expect(wrapper.get('[data-testid="theme-picker-label"]').text()).toBe('Tokyo Night')
    expect(wrapper.find('[data-testid="theme-picker"]').exists()).toBe(false)
  })

  it('filters the list as the user types', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    await wrapper.get('[data-testid="theme-search"]').setValue('github')

    expect(wrapper.find('[data-testid="theme-option-github-dark"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="theme-option-github-light"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="theme-option-dracula"]').exists()).toBe(false)
  })

  it('says so when the search matches nothing', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    await wrapper.get('[data-testid="theme-search"]').setValue('solarized')

    expect(wrapper.get('[data-testid="theme-picker-empty"]').text()).toContain('solarized')
  })

  it('picks the highlighted theme with Enter', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    const search = wrapper.get('[data-testid="theme-search"]')
    await search.setValue('dracula')
    await search.trigger('keydown', { key: 'Enter' })

    expect(root().dataset.theme).toBe('dracula')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('dracula')
  })

  it('closes when Escape is pressed', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    await wrapper.get('[data-testid="theme-search"]').trigger('keydown', { key: 'Escape' })

    expect(wrapper.find('[data-testid="theme-picker"]').exists()).toBe(false)
  })

  it('closes when the user clicks outside', async () => {
    wrapper = mountSection()
    await openPicker(wrapper)

    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await wrapper.vm.$nextTick()

    expect(wrapper.find('[data-testid="theme-picker"]').exists()).toBe(false)
  })

  it('starts on the theme the last session stored', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'atom-one-light')

    wrapper = mountSection()

    expect(wrapper.get('[data-testid="theme-picker-label"]').text()).toBe('Atom One Light')
  })
})

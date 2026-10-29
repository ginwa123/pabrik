import { beforeEach, describe, expect, it } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'

import AppearanceSection from '../components/settings/AppearanceSection.vue'
import { THEMES, THEME_STORAGE_KEY } from '../theme/themes'
import { makeLocalStorageStub } from './helpers'

const root = (): HTMLElement => document.documentElement

function mountSection(): VueWrapper {
  return mount(AppearanceSection)
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

  it('offers every theme the app ships, with the current one selected', () => {
    wrapper = mountSection()
    const radios = wrapper.findAll('input[name="pabrik-theme"]')

    expect(radios.map((radio) => radio.attributes('value'))).toEqual(
      THEMES.map((theme) => theme.id),
    )
    expect((wrapper.get('[data-testid="theme-radio-dark"]').element as HTMLInputElement).checked).toBe(
      true,
    )
  })

  it('repaints the app and remembers the choice when Light is chosen', async () => {
    wrapper = mountSection()

    await wrapper.get('[data-testid="theme-radio-light"]').setValue()

    expect(root().dataset.theme).toBe('light')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('light')
    expect(
      (wrapper.get('[data-testid="theme-radio-light"]').element as HTMLInputElement).checked,
    ).toBe(true)
  })

  it('shows the theme the last session stored as the selected one', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'light')

    wrapper = mountSection()

    expect(
      (wrapper.get('[data-testid="theme-radio-light"]').element as HTMLInputElement).checked,
    ).toBe(true)
    expect(
      (wrapper.get('[data-testid="theme-radio-dark"]').element as HTMLInputElement).checked,
    ).toBe(false)
  })
})

import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import PabrikConfigEditor from '../components/pabrik/PabrikConfigEditor.vue'
import { __resetWindowIdForTests } from '../helpers/windowId'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

/**  * Task 7 of the tab-mode plan: the "Browser-style tabs" switch in Settings → General. It is an app
 * preference (localStorage), not a config.json field — the tab set lives client-side, so there is
 * nothing for the backend to store. */

vi.mock('../api', () => ({
  getPabrikConfig: vi.fn(),
  savePabrikConfig: vi.fn(),
  deleteProfile: vi.fn(),
  getWebStatus: vi.fn(),
}))

const mockGet = api.getPabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>

function installStorage(): void {
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  Object.defineProperty(globalThis, 'sessionStorage', {
    value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_settings' }),
    writable: true,
    configurable: true,
  })
}

async function mountSettings() {
  mockGet.mockResolvedValueOnce({})
  const wrapper = mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
  await flushPromises()
  return wrapper
}

describe('PabrikConfigEditor — Browser-style tabs toggle', () => {
  beforeEach(() => {
    installStorage()
    __resetWindowIdForTests()
    setActivePinia(createPinia())
    mockGet.mockReset()
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
  })

  it('renders the toggle in the General tab, off by default', async () => {
    const wrapper = await mountSettings()
    const toggle = wrapper.find('[data-testid="toggle-browser-tabs"]')
    expect(wrapper.find('[data-testid="row-browser-tabs"]').exists()).toBe(true)
    expect((toggle.element as HTMLInputElement).checked).toBe(false)
  })

  it('persists the preference and never writes it to the server config', async () => {
    const wrapper = await mountSettings()
    const tabs = useTabsStore()
    const mockSave = api.savePabrikConfig as unknown as ReturnType<typeof vi.fn>
    mockSave.mockReset()

    // Default is OFF — opt in first so the change event fires both ways.
    await wrapper.find('[data-testid="toggle-browser-tabs"]').setValue(true)

    expect(tabs.enabled).toBe(true)
    expect(localStorage.getItem('pabrik-tabs-enabled')).toBe('true')
    expect(mockSave).not.toHaveBeenCalled()

    await wrapper.find('[data-testid="toggle-browser-tabs"]').setValue(false)
    expect(tabs.enabled).toBe(false)
    expect(localStorage.getItem('pabrik-tabs-enabled')).toBe('false')
  })

  it('survives a remount with the pref off and can be turned back on', async () => {
    const tabs = useTabsStore()
    tabs.setEnabled(false)

    const wrapper = await mountSettings()
    expect(
      (wrapper.find('[data-testid="toggle-browser-tabs"]').element as HTMLInputElement).checked,
    ).toBe(false)

    await wrapper.find('[data-testid="toggle-browser-tabs"]').setValue(true)
    expect(useTabsStore().enabled).toBe(true)
  })
})

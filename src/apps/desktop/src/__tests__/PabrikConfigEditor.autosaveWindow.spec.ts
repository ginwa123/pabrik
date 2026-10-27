/** The autosave WINDOW itself: a burst of edits collapses into one PUT, and leaving the page with
 * an edit still inside that window still writes it. The rest of the editor specs mount the window at
 * 0 ms; this one keeps the real 600 ms and drives it with fake timers. */
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import PabrikConfigEditor from '../components/pabrik/PabrikConfigEditor.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('../api', () => ({
  getPabrikConfig: vi.fn(),
  savePabrikConfig: vi.fn(),
  deleteAgent: vi.fn(),
  getWebStatus: vi.fn(),
  getAgentToolsRegistry: vi.fn(),
  getModelCatalog: vi.fn(),
  getAgentProfileInUse: vi.fn(),
  resolveModelOutcome: vi.fn(),
}))

const mockGet = api.getPabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockSave = api.savePabrikConfig as unknown as ReturnType<typeof vi.fn>
const mockWebStatus = api.getWebStatus as unknown as ReturnType<typeof vi.fn>
const mockModelCatalog = api.getModelCatalog as unknown as ReturnType<typeof vi.fn>

/** Let queued promises settle without moving the clock forward. */
async function settle() {
  await vi.advanceTimersByTimeAsync(0)
}

function mountEditor() {
  return mount(PabrikConfigEditor, { global: { stubs: { Teleport: true } } })
}

describe('PabrikConfigEditor — autosave window', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    setActivePinia(createPinia())
    mockGet.mockReset()
    mockSave.mockReset()
    mockSave.mockResolvedValue({ success: true })
    mockWebStatus.mockReset()
    mockWebStatus.mockResolvedValue(null)
    mockModelCatalog.mockReset()
    mockModelCatalog.mockResolvedValue({ models: [], total: 0, state: 'absent' })
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('collapses a burst of edits into one PUT, carrying every change', async () => {
    mockGet.mockResolvedValueOnce({ notify_on_complete: false, notify_on_error: false })
    const wrapper = mountEditor()
    await settle()

    await wrapper.find('[data-testid="toggle-notify-on-error"]').setValue(true)
    await settle()
    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    await settle()

    // Still inside the window: nothing has left the browser yet.
    expect(mockSave).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(600)

    expect(mockSave).toHaveBeenCalledTimes(1)
    expect(mockSave.mock.calls[0]![0]).toMatchObject({
      notify_on_error: true,
      notify_on_complete: true,
    })
  })

  it('writes a pending edit when the page is left before the window elapses', async () => {
    mockGet.mockResolvedValueOnce({ notify_on_complete: false })
    const wrapper = mountEditor()
    await settle()

    await wrapper.find('[data-testid="toggle-notify-on-complete"]').setValue(true)
    await settle()
    expect(mockSave).not.toHaveBeenCalled()

    wrapper.unmount()
    await settle()

    expect(mockSave).toHaveBeenCalledTimes(1)
    expect(mockSave.mock.calls[0]![0]).toMatchObject({ notify_on_complete: true })
  })

  it('does not write anything when the page is left untouched', async () => {
    mockGet.mockResolvedValueOnce({ notify_on_complete: false })
    const wrapper = mountEditor()
    await settle()

    wrapper.unmount()
    await settle()
    await vi.advanceTimersByTimeAsync(600)

    expect(mockSave).not.toHaveBeenCalled()
  })
})

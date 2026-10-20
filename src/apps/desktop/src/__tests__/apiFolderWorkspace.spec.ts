/** The folder API must NAME the workspace it means: under `--saas` the server
 *  lists a workspace's VM, so a request that does not say which one is
 *  refused. The app shows one workspace at a time — the current one. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import * as api from '../api'
import { resetWorkspaceScopeForTest, setCurrentWorkspaceId } from '../helpers/workspaceScope'

describe('the folder API names the workspace', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    global.fetch = fetchMock as unknown as typeof fetch
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ entries: [] }),
      text: () => Promise.resolve('{"entries":[]}'),
    } as unknown as Response)
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
    resetWorkspaceScopeForTest()
  })

  /** The URL the api layer asked for. */
  function requestedUrl(): string {
    return String(fetchMock.mock.calls[0]?.[0] ?? '')
  }

  it('names the workspace the app is on when the caller does not', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.listFolder('/workspace')

    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('names the workspace the caller means when it is not the current one', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.listFolder('/workspace', 'ws_other')

    expect(requestedUrl()).toContain('workspace_id=ws_other')
    expect(requestedUrl()).not.toContain('ws_current')
  })

  it('names the workspace when the caller asks for the root', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.getSystemFolder()

    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('names the workspace when the caller searches', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.searchFiles('/workspace', 'needle')

    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('names the workspace when the caller lists a directory', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.listFiles('/workspace')

    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('names no workspace when the app is on none', async () => {
    setCurrentWorkspaceId(null)

    await api.listFolder('/workspace')

    expect(requestedUrl()).not.toContain('workspace_id')
  })
})

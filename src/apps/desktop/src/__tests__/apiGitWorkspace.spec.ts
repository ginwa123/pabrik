/** Every `/api/git/*` request must NAME the workspace it means: under `--saas`
 *  the tree lives in the workspace's VM, and a bare `path` cannot identify it,
 *  so the server has no workspace to resolve. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import * as api from '../api'
import { forgetGitProbe } from '../helpers/gitProbeGate'
import { resetWorkspaceScopeForTest, setCurrentWorkspaceId } from '../helpers/workspaceScope'

describe('the git API names the workspace', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    // The probe gate remembers a cwd for the whole module: one test's answer
    // must not silence the next test's request.
    forgetGitProbe('/workspace')
    global.fetch = fetchMock as unknown as typeof fetch
    fetchMock.mockResolvedValue({
      ok: true,
      status: 200,
      json: () =>
        Promise.resolve({ is_git_repo: false, branch: '', has_changes: false, is_clean: true }),
      text: () => Promise.resolve('{}'),
    } as unknown as Response)
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
    resetWorkspaceScopeForTest()
  })

  function requestedUrl(index = 0): string {
    return String(fetchMock.mock.calls[index]?.[0] ?? '')
  }

  it('names the workspace the app is on when it asks for git status', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.getGitStatus('/workspace')

    expect(requestedUrl()).toContain('/api/git/status')
    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('keeps the path it was given, so the server still knows which tree', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.getGitStatus('/workspace')

    expect(requestedUrl()).toContain('path=%2Fworkspace')
  })

  it('adds the workspace to a write, which carries no path in its URL', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.stageGitFiles('/workspace', ['a.txt'])

    expect(requestedUrl()).toContain('/api/git/stage')
    expect(requestedUrl()).toContain('workspace_id=ws_current')
  })

  it('says nothing when the app is on no workspace, so local mode is untouched', async () => {
    setCurrentWorkspaceId(null)

    await api.getGitStatus('/workspace')

    expect(requestedUrl()).toContain('/api/git/status')
    expect(requestedUrl()).not.toContain('workspace_id')
  })

  it('leaves a non-git request alone', async () => {
    setCurrentWorkspaceId('ws_current')

    await api.healthCheck()

    expect(requestedUrl()).toContain('/api/health')
    expect(requestedUrl()).not.toContain('workspace_id')
  })
})

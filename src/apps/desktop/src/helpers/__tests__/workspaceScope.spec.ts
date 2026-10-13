import { describe, expect, it } from 'vitest'

import { resolveWorkspaceId } from '../workspaceScope'

describe('resolveWorkspaceId', () => {
  it('prefers the route path over the store', () => {
    expect(resolveWorkspaceId('ws_from_url', 'ws_from_store')).toBe('ws_from_url')
  })

  it('falls back to the active workspace when the route has none', () => {
    // Legacy workspace-less routes (`/app`, `/app/chat/:sessionId`) and the
    // router-less mounts specs use.
    expect(resolveWorkspaceId(undefined, 'ws_from_store')).toBe('ws_from_store')
    expect(resolveWorkspaceId('', 'ws_from_store')).toBe('ws_from_store')
  })

  it('yields an empty id when neither source names a workspace', () => {
    // Empty is meaningful: it means "no workspace in scope", and the callers
    // must not substitute a guess (`workspaces[0]`).
    expect(resolveWorkspaceId(undefined, undefined)).toBe('')
    expect(resolveWorkspaceId('', null)).toBe('')
  })

  it('ignores a non-string param (a repeated param arrives as an array)', () => {
    expect(resolveWorkspaceId(['ws_a', 'ws_b'], 'ws_from_store')).toBe('ws_from_store')
  })
})

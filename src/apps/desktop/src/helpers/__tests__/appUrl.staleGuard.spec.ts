import { describe, expect, it } from 'vitest'
import { isChatRouteStaleForSession } from '../appUrl'

/** Regression: left-sidebar chat click did nothing after opening a file in the right sidebar
 * (Changes tab). Root cause: ChatView's diff URL writers (`syncDiffParam`, `syncDiffQuery`) guarded
 * only legacy `?view=/?session=` query URLs. */
describe('isChatRouteStaleForSession — dying view must not touch the URL', () => {
  const WS = 'ws_1'
  const A = 'sess_A'
  const B = 'sess_B'

  it('fresh: own chat path is writable', () => {
    expect(isChatRouteStaleForSession(`/app/${WS}/chat/${A}`, A)).toBe(false)
  })

  it('stale: new chat path seen from dying view is not writable', () => {
    // The exact repro: A open with a diff, user clicks B in the left
    // sidebar, ChatsList pushes /app/ws/chat/B, A's spy fires late.
    expect(isChatRouteStaleForSession(`/app/${WS}/chat/${B}`, A)).toBe(true)
  })

  it('stale: old chat path seen from the new view is not writable', () => {
    // Symmetric: B mounted while route still names A (router guard pending).
    expect(isChatRouteStaleForSession(`/app/${WS}/chat/${A}`, B)).toBe(true)
  })

  it('stale: task-chat mismatch is not writable', () => {
    expect(isChatRouteStaleForSession(`/app/${WS}/projects/p_1/chat/task_1`, 'task_2')).toBe(true)
  })

  it('fresh: matching task-chat is writable', () => {
    expect(isChatRouteStaleForSession(`/app/${WS}/projects/p_1/chat/task_1`, 'task_1')).toBe(false)
  })

  it('stale: workspace / project / doc surfaces never belong to ChatView', () => {
    expect(isChatRouteStaleForSession(`/app/${WS}`, A)).toBe(true)
    expect(isChatRouteStaleForSession(`/app/${WS}/projects/p_1`, A)).toBe(true)
    expect(isChatRouteStaleForSession(`/app/${WS}/doc/d_1`, A)).toBe(true)
  })

  it('fresh: landing and unknown paths defer to legacy query guards', () => {
    expect(isChatRouteStaleForSession('/app', A)).toBe(false)
    expect(isChatRouteStaleForSession('/app/settings', A)).toBe(false)
  })

  it('positive control: parseAppPath still extracts the session the guard reads', () => {
    // Guards against a vacuous test where every path is stale because the
    // parser broke: the matching-session case must stay writable.
    expect(isChatRouteStaleForSession(`/app/${WS}/chat/${B}`, B)).toBe(false)
  })
})

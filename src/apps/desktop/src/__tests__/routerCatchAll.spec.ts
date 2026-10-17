import { describe, it, expect } from 'vitest'

import router from '../router/index'

/** Global catch-all (`/:pathMatch(.*)*` → `/app`). The backend serves index.html for any
 * route-style path under /app (static_files.zig SPA fallback), so a refresh at a deep link always
 * boots the SPA — but without a matching frontend route Vue renders an empty router-view. */
describe('router catch-all', () => {
  it('redirects an unknown /app deep link to /app', async () => {
    await router.push('/app/kanban/ghost-item')
    expect(router.currentRoute.value.path).toBe('/app')
  })

  it('redirects a totally unknown path to /app', async () => {
    await router.push('/definitely/not/a/route')
    expect(router.currentRoute.value.path).toBe('/app')
  })

  it('keeps known routes intact', async () => {
    await router.push('/app/settings')
    expect(router.currentRoute.value.path).toBe('/app/settings')

    await router.push('/app/chat/sess_123')
    expect(router.currentRoute.value.path).toBe('/app/chat/sess_123')

    await router.push('/app/kanban/item_1/settings')
    expect(router.currentRoute.value.path).toBe('/app/kanban/item_1/settings')

    // Would land on /app via the catch-all if this route were registered
    // after it.
    await router.push('/app/ws_1/projects/item_7/add')
    expect(router.currentRoute.value.path).toBe('/app/ws_1/projects/item_7/add')
  })
})

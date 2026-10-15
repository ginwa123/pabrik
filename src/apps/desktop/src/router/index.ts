import { createRouter, createWebHistory } from 'vue-router'
import AppLayout from '../components/AppLayout.vue'
import LoginView from '../views/LoginView.vue'
import { getAuthMeCached } from '../helpers/authMe'
import { useLoadingStore } from '../stores/loading'
import { getCurrentUserId, purgeForeignScopedKeys, setCurrentUserId } from '../helpers/userScope'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      redirect: '/app',
    },
    {
      path: '/login',
      name: 'login',
      component: LoginView,
      meta: { public: true },
    },
    {
      path: '/app',
      name: 'app',
      component: AppLayout,
    },
    {
      path: '/app/settings',
      name: 'settings',
      component: AppLayout,
    },
    // Catch-all route for chat links with session ID
    {
      path: '/app/chat/:sessionId',
      name: 'chat',
      component: AppLayout,
    },
    // Catch-all route for task links with task ID
    {
      path: '/app/task/:taskId',
      name: 'task',
      component: AppLayout,
    },
    // Kanban settings page (plan: 2026-09-02-kanban-settings-as-page).
    // Resolves to AppLayout which dispatches via the `currentView`
    // AppLayout.handleOpenKanbanSettings via `router.push`.
    {
      path: '/app/kanban/:itemId/settings',
      name: 'kanban-settings',
      component: AppLayout,
    },
    // Path-based URL contract (plan: 2026-09-22-revamp-ui-chats).
    // Most-specific first — vue-router matches in registration order.
    // These come AFTER the reserved single-segment routes above
    // (`settings`, legacy `chat`/`task`) and the kanban-settings path,
    // otherwise `/app/chat/X` would match with workspaceId='chat'.
    // See `helpers/appUrl.ts` (single builder / parser) and
    // `parseAppPath`'s RESERVED_FIRST_SEGMENTS guard.
    {
      path: '/app/:workspaceId/projects/:projectId/chat/:taskId',
      name: 'project-chat',
      component: AppLayout,
    },
    {
      path: '/app/:workspaceId/projects/:projectId',
      name: 'project',
      component: AppLayout,
    },
    {
      path: '/app/:workspaceId/chat/:sessionId',
      name: 'workspace-chat',
      component: AppLayout,
    },
    // Document page (Migration 095). A PAGE shape, not a `?doc=` overlay:
    // the document replaces the main view, so it must own its own path
    // instead of borrowing whichever one happened to be open underneath.
    // Must stay BEFORE `/app/:workspaceId` — Vue matches in order, and
    // that route's catch would otherwise never see the `/doc` segment.
    {
      path: '/app/:workspaceId/doc/:documentId',
      name: 'workspace-doc',
      component: AppLayout,
    },
    // Workspace settings page. Which settings SECTION is open is a query
    // param (`?section=`), not a second path segment — `?tab=` belongs to
    // browser tab-mode. Must stay BEFORE `/app/:workspaceId`: Vue matches
    // in registration order and that route's catch would otherwise swallow
    // `/app/ws_1/settings` as `workspaceId='ws_1'` and drop the `/settings`
    // segment entirely. Same trap as `/app/:workspaceId/chat/:sessionId`
    // and `/app/:workspaceId/doc/:documentId` above.
    {
      path: '/app/:workspaceId/settings',
      name: 'workspace-settings',
      component: AppLayout,
    },
    {
      path: '/app/:workspaceId',
      name: 'workspace',
      component: AppLayout,
    },
    // Global catch-all: any path the backend's SPA fallback serves index.html for but no route
    // above matches (stale deep link, refresh at a removed URL) lands on /app instead of rendering
    // an empty router-view. Must stay LAST — Vue matches in order.
    {
      path: '/:pathMatch(.*)*',
      redirect: '/app',
    },
  ],
})

// Auth guard: when the backend runs with `--auth`, every `/app*`
// view requires a valid `pabrik_session` cookie. Anonymous visits
// redirect to `/login?redirect=<target>` (router.replace, so Back
// skips the bounce); authed visits to `/login` bounce back to the
// target. Public when auth is off (`/api/auth/me` 200 +
// auth_enabled=false) — no redirect. Every view switch stays in the
// URL (repo rule), so refresh/Back/shared links keep working.
//
// The top loading bar is driven here: start on beforeEach (covers the async auth check, which is
// the slowest part of a redirect), finish on afterEach/onError. Lazily resolved inside the guard so
// the router module never hard-depends on an installed pinia (specs import the router without one).
function loadingStore() {
  try {
    return useLoadingStore()
  } catch {
    return null
  }
}

/**
 * Apply the identity reported by `/api/auth/me` to the storage scope
 * (plan 2026-09-25, W5).
 *
 * Called from the guard on EVERY navigation, before any view renders, so:
 *  - the first paint after a reload happens with the correct scope (a
 *    data-bearing key read during mount resolves to this user's slot, never
 *    the previous user's);
 *  - an identity CHANGE (A logs out, B logs in — or a sibling tab switched
 *    users) purges the previous user's scoped keys before B's first paint.
 *
 * `auth_enabled === false` (or an unauthenticated response) means there is no
 * identity: the scope is cleared and keys stay unscoped, which is the
 * auth-off behaviour.
 */
function applyIdentity(
  data: { auth_enabled?: boolean; authenticated?: boolean; user?: { id?: string } } | null,
): void {
  const nextId =
    data && data.auth_enabled !== false && data.authenticated === true && data.user?.id
      ? data.user.id
      : null
  const previousId = getCurrentUserId()
  if (previousId !== nextId) {
    // Identity changed (including "was A, now nobody"): drop the previous
    // user's scoped keys so they can never be painted under the new scope.
    setCurrentUserId(nextId)
    purgeForeignScopedKeys()
  } else {
    setCurrentUserId(nextId)
  }
}

router.beforeEach(async (to) => {
  loadingStore()?.startRoute()
  if (to.meta.public) {
    // Leaving /login while authed? Bounce to the redirect target.
    if (to.name === 'login') {
      try {
        // Cached: a slow /me must not block leaving /login (see helpers/authMe).
        const { data } = await getAuthMeCached()
        applyIdentity(data)
        if (data && data.authenticated === true) {
          const r = to.query.redirect
          const target = typeof r === 'string' && r.startsWith('/') ? r : '/app'
          return { path: target, replace: true }
        }
      } catch {
        /* offline — show login */
      }
    }
    return true
  }
  try {
    // Cached + 4s timeout: the async auth check was the slowest part of
    // a redirect (~20s on a busy boot) — see helpers/authMe.
    const { status, data } = await getAuthMeCached()
    applyIdentity(data)
    if (data) {
      // Auth disabled on server → open access, no redirect.
      if (data.auth_enabled === false) return true
      if (data.authenticated === true) return true
    }
    if (status === 401) {
      return { path: '/login', query: { redirect: to.fullPath }, replace: true }
    }
    // Non-401 error (offline/500): let the view render; apiFetch
    // toasts will surface the failure. Avoids login-loop on outage.
    return true
  } catch {
    return true
  }
})

router.afterEach(() => {
  loadingStore()?.finishRoute()
})

router.onError(() => {
  loadingStore()?.finishRoute()
})

export default router

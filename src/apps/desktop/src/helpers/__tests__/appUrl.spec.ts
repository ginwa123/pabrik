import { describe, expect, it } from 'vitest'
import {
  buildAppUrl,
  buildSettingsUrl,
  buildTaskAppUrl,
  detectLegacyAppUrl,
  isAppPath,
  normalizeAppPath,
  parseAppPath,
} from '../appUrl'

describe('appUrl — path-based URL contract (2026-09-22 revamp)', () => {
  describe('buildSettingsUrl', () => {
    it('carries the workspace in the path, so settings always knows its scope', () => {
      expect(buildSettingsUrl('ws_1')).toEqual({ path: '/app/ws_1/settings', query: {} })
    })
    it('passes the remembered section through as ?section=', () => {
      expect(buildSettingsUrl('ws_1', 'profiles')).toEqual({
        path: '/app/ws_1/settings',
        query: { section: 'profiles' },
      })
    })
    it('drops an empty section rather than emitting ?section=', () => {
      expect(buildSettingsUrl('ws_1', '')).toEqual({ path: '/app/ws_1/settings', query: {} })
      expect(buildSettingsUrl('ws_1', null)).toEqual({ path: '/app/ws_1/settings', query: {} })
    })
    it('user scope only when no workspace is in scope at all', () => {
      // `/app/settings` is General-only and genuinely not about a workspace;
      // it must never be the answer for a known workspace (that is the bug:
      // the URL lost the workspace and the Workspace tab then guessed one).
      expect(buildSettingsUrl('')).toEqual({ path: '/app/settings', query: {} })
      expect(buildSettingsUrl(undefined)).toEqual({ path: '/app/settings', query: {} })
      expect(buildSettingsUrl('  ')).toEqual({ path: '/app/settings', query: {} })
    })
    it('never sends a section to the user-scope page', () => {
      // `profiles` is workspace-scoped since Migration 105; the user page has
      // no such tab, so a `?section=profiles` there would name a tab it cannot
      // render.
      expect(buildSettingsUrl('', 'profiles')).toEqual({ path: '/app/settings', query: {} })
    })
  })

  describe('buildAppUrl', () => {
    it('landing: no ids → /app', () => {
      expect(buildAppUrl({})).toEqual({ path: '/app', query: {} })
    })
    it('workspace: /app/{ws}', () => {
      expect(buildAppUrl({ workspaceId: 'ws_1' })).toEqual({ path: '/app/ws_1', query: {} })
    })
    it('chat: /app/{ws}/chat/{sid}', () => {
      expect(buildAppUrl({ workspaceId: 'ws_1', chatSessionId: 'sess_9' })).toEqual({
        path: '/app/ws_1/chat/sess_9',
        query: {},
      })
    })
    it('project: /app/{ws}/projects/{pid} (+ query sub-state)', () => {
      expect(
        buildAppUrl({ workspaceId: 'ws_1', projectId: 'item_7', query: { sorts: 'a:b:asc' } }),
      ).toEqual({ path: '/app/ws_1/projects/item_7', query: { sorts: 'a:b:asc' } })
    })
    it('project chat: /app/{ws}/projects/{pid}/chat/{tid}', () => {
      expect(
        buildAppUrl({ workspaceId: 'ws_1', projectId: 'item_7', chatTaskId: 'task_3' }),
      ).toEqual({ path: '/app/ws_1/projects/item_7/chat/task_3', query: {} })
    })
    it('throws on incoherent combinations', () => {
      expect(() => buildAppUrl({ chatSessionId: 's' })).toThrow('workspaceId is required')
      expect(() => buildAppUrl({ workspaceId: 'w', chatSessionId: 's', projectId: 'p' })).toThrow(
        'cannot combine',
      )
      expect(() => buildAppUrl({ workspaceId: 'w', chatTaskId: 't' })).toThrow(
        'chatTaskId requires projectId',
      )
    })
  })

  describe('parseAppPath', () => {
    it('parses all five shapes', () => {
      expect(parseAppPath('/app')).toEqual({ kind: 'landing' })
      expect(parseAppPath('/app/ws_1')).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
      expect(parseAppPath('/app/ws_1/chat/sess_9')).toEqual({
        kind: 'chat',
        workspaceId: 'ws_1',
        sessionId: 'sess_9',
      })
      expect(parseAppPath('/app/ws_1/projects/item_7')).toEqual({
        kind: 'project',
        workspaceId: 'ws_1',
        projectId: 'item_7',
      })
      expect(parseAppPath('/app/ws_1/projects/item_7/chat/task_3')).toEqual({
        kind: 'projectChat',
        workspaceId: 'ws_1',
        projectId: 'item_7',
        chatTaskId: 'task_3',
      })
    })
    it('tolerates trailing slashes', () => {
      expect(parseAppPath('/app/ws_1/')).toEqual({ kind: 'workspace', workspaceId: 'ws_1' })
      expect(parseAppPath('/app/ws_1/projects/item_7/')).toEqual({
        kind: 'project',
        workspaceId: 'ws_1',
        projectId: 'item_7',
      })
    })
    it('non-app paths → other', () => {
      expect(parseAppPath('/app/settings')).toEqual({ kind: 'other', path: '/app/settings' })
      expect(parseAppPath('/app/kanban/i_1/settings')).toEqual({
        kind: 'other',
        path: '/app/kanban/i_1/settings',
      })
      expect(parseAppPath('/app/chat/sess_9')).toEqual({ kind: 'other', path: '/app/chat/sess_9' })
      expect(parseAppPath('/login')).toEqual({ kind: 'other', path: '/login' })
    })
  })

  describe('normalizeAppPath / isAppPath', () => {
    it('strips trailing slashes, keeps root', () => {
      expect(normalizeAppPath('/app/ws_1/')).toBe('/app/ws_1')
      expect(normalizeAppPath('/app/ws_1///')).toBe('/app/ws_1')
      expect(normalizeAppPath('/app')).toBe('/app')
      expect(normalizeAppPath('/')).toBe('/')
      expect(normalizeAppPath('')).toBe('/app')
    })
    it('isAppPath matches the five shapes only', () => {
      expect(isAppPath('/app')).toBe(true)
      expect(isAppPath('/app/ws_1/chat/s')).toBe(true)
      expect(isAppPath('/app/settings')).toBe(false)
      expect(isAppPath('/app/chat/s')).toBe(false)
    })
  })

  describe('buildTaskAppUrl', () => {
    it('emits the project-chat path from store state', () => {
      expect(
        buildTaskAppUrl({
          taskId: 'task_3',
          activeWorkspaceId: 'ws_1',
          activeWorkspaceItemId: 'item_7',
        }),
      ).toEqual({ path: '/app/ws_1/projects/item_7/chat/task_3', query: {} })
    })
    it('carries pageId/sorts sub-state, drops the view key', () => {
      expect(
        buildTaskAppUrl({
          taskId: 'task_3',
          activeWorkspaceId: 'ws_1',
          activeWorkspaceItemId: 'item_7',
          activeDesignPageId: 'page_1',
          activeItemType: 'design',
          currentQuery: { sorts: 'c:x:asc' },
        }),
      ).toEqual({
        path: '/app/ws_1/projects/item_7/chat/task_3',
        query: { pageId: 'page_1', sorts: 'c:x:asc' },
      })
    })
    it('falls back to the URL breadcrumb without store state', () => {
      expect(
        buildTaskAppUrl({
          taskId: 'task_3',
          currentQuery: { workspaceId: 'ws_9', itemId: 'item_8' },
        }),
      ).toEqual({ path: '/app/ws_9/projects/item_8/chat/task_3', query: {} })
    })
  })

  describe('document page shape (Migration 095)', () => {
    it('parses /app/{ws}/doc/{id}', () => {
      expect(parseAppPath('/app/ws_1/doc/doc_9')).toEqual({
        kind: 'doc',
        workspaceId: 'ws_1',
        documentId: 'doc_9',
      })
    })
    it('ignores a trailing slash', () => {
      expect(parseAppPath('/app/ws_1/doc/doc_9/')).toEqual({
        kind: 'doc',
        workspaceId: 'ws_1',
        documentId: 'doc_9',
      })
    })
    it('does not swallow the sibling shapes', () => {
      // `doc` and `chat` have the same segment count, so an ordering slip
      // in the parser would silently turn a document into a chat.
      expect(parseAppPath('/app/ws_1/chat/s').kind).toBe('chat')
      expect(parseAppPath('/app/ws_1').kind).toBe('workspace')
      expect(parseAppPath('/app/ws_1/projects/p').kind).toBe('project')
      expect(parseAppPath('/app/ws_1/projects/p/chat/t').kind).toBe('projectChat')
    })
    it('a bare /app/doc is NOT a workspace named "doc"', () => {
      // Otherwise a malformed document URL boots the user into a
      // workspace that does not exist.
      expect(parseAppPath('/app/doc').kind).toBe('other')
    })
    it('builds /app/{ws}/doc/{id} and carries sub-state', () => {
      expect(
        buildAppUrl({ workspaceId: 'ws_1', documentId: 'doc_9', query: { tab: 't1' } }),
      ).toEqual({ path: '/app/ws_1/doc/doc_9', query: { tab: 't1' } })
    })
    it('a document is exclusive with chat/project targets', () => {
      // Both at once means the caller lost track of what it navigates to;
      // silently picking one would hide the bug behind a wrong URL.
      expect(() =>
        buildAppUrl({ workspaceId: 'ws_1', documentId: 'doc_9', chatSessionId: 's' }),
      ).toThrow(/cannot combine/)
      expect(() =>
        buildAppUrl({ workspaceId: 'ws_1', documentId: 'doc_9', projectId: 'p' }),
      ).toThrow(/cannot combine/)
    })
    it('requires a workspace', () => {
      expect(() => buildAppUrl({ documentId: 'doc_9' })).toThrow(/workspaceId is required/)
    })
    it('a document path is canonical (no legacy rewrite)', () => {
      expect(detectLegacyAppUrl('/app/ws_1/doc/doc_9', {})).toBeNull()
    })
  })

  describe('detectLegacyAppUrl', () => {
    it('canonical URLs → null', () => {
      expect(detectLegacyAppUrl('/app', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1/chat/s', {})).toBeNull()
      expect(detectLegacyAppUrl('/app/ws_1/projects/p', { sorts: 'x' })).toBeNull()
    })
    it('trailing slash → normalize target', () => {
      expect(detectLegacyAppUrl('/app/ws_1/', {})).toEqual({ path: '/app/ws_1', query: {} })
    })
    it('legacy path routes → __legacy marker', () => {
      expect(detectLegacyAppUrl('/app/chat/sess_9', {})).toEqual({
        path: null,
        query: { __legacy: 'chat:sess_9' },
      })
      expect(detectLegacyAppUrl('/app/task/task_3', {})).toEqual({
        path: null,
        query: { __legacy: 'task:task_3' },
      })
    })
    it('legacy ?view= URLs → __legacy marker, view dropped, rest preserved', () => {
      expect(detectLegacyAppUrl('/app', { view: 'chat', session: 'sess_9', tab: 'tab_1' })).toEqual(
        { path: null, query: { session: 'sess_9', tab: 'tab_1', __legacy: 'view:chat' } },
      )
      expect(
        detectLegacyAppUrl('/app', { view: 'workspace', workspaceId: 'ws_1', itemId: 'i_2' }),
      ).toEqual({
        path: null,
        query: { workspaceId: 'ws_1', itemId: 'i_2', __legacy: 'view:workspace' },
      })
      expect(detectLegacyAppUrl('/app', { view: 'task', task: 't' })).toEqual({
        path: null,
        query: { task: 't', __legacy: 'view:task' },
      })
    })
    it('unknown ?view= values pass through untouched', () => {
      expect(detectLegacyAppUrl('/app', { view: 'gitfile' })).toBeNull()
    })
  })
})

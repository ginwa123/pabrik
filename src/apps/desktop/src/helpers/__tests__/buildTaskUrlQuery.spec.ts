/**
 * Behavioural tests for `buildTaskUrlQuery` and `pickBreadcrumbFromChat`.
 *
 * Plans:
 *   - docs/superpowers/plans/2026-08-06-add-workspace-id-params.md (workspaceId always present)
 *   - docs/superpowers/plans/2026-08-15-simplify-url-browser.md (collapse view=task into /chat/ suffix)
 *
 * The user's report (task_1785774094183): task URLs were missing
 * `workspaceId`. The 2026-08-06 helper fixed that.
 *
 * The 2026-08-15 simplify-url-browser refactor changed the wire
 * shape: the helper now emits `view=workspace` (NOT `view=task`)
 * with the chat task id encoded as `/chat/<taskId>` suffix on
 * `itemId`. The redundant `session` query param is dropped
 * (per `task.id == session_id`, the chat task id in the suffix
 * IS the session id).
 */
import { describe, expect, it } from 'vitest'
import { buildTaskUrlQuery, pickBreadcrumbFromQuery } from '../buildTaskUrlQuery'

const WS_ID = 'ws_a'
const ITEM_ID = 'item_kanban'
const TASK_ID = 'task_1'

describe('buildTaskUrlQuery — emits view=workspace + /chat/<taskId> suffix (simplify-url-browser 2026-08-15)', () => {
  it('includes workspaceId + itemId-with-chat-suffix when active store is set', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: ITEM_ID,
    })
    expect(query.view).toBe('workspace')
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
    expect((query as Record<string, unknown>).task).toBeUndefined()
  })

  it('includes pageId only when active item is a design', () => {
    const design = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: 'item_design',
      activeDesignPageId: 'page_xyz',
      activeItemType: 'design',
    })
    expect(design.pageId).toBe('page_xyz')

    const kanban = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: 'item_kanban',
      activeDesignPageId: 'page_xyz', // stale from a prior design
      activeItemType: 'kanban',
    })
    expect(kanban.pageId).toBeUndefined()

    const folder = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: 'item_folder',
      activeDesignPageId: 'page_xyz', // stale from a prior design
      activeItemType: 'folder',
    })
    expect(folder.pageId).toBeUndefined()
  })

  it('omits pageId when activeItemType is missing even if activeDesignPageId is set', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: 'item_kanban',
      activeDesignPageId: 'page_xyz',
      // activeItemType omitted
    })
    expect(query.pageId).toBeUndefined()
  })

  it('omits workspaceId + itemId when neither store nor URL has them (deep-link)', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
    })
    expect(query.view).toBe('workspace')
    expect(query.workspaceId).toBeUndefined()
    expect(query.itemId).toBeUndefined()
    // No chat suffix when no item id at all
    expect((query as Record<string, unknown>).task).toBeUndefined()
  })

  it('falls back to URL breadcrumb when store has no active workspace', () => {
    // The user landed on the chat via a deep link with workspaceId
    // already in the URL (possibly the new shape). The new task URL
    // must preserve that breadcrumb.
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      currentQuery: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
        sorts: 'col_a:name:asc',
      },
    })
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
    expect(query.sorts).toBe('col_a:name:asc')
  })

  it('carries ?layout= through the task URL (kanban row mode round-trip)', () => {
    // `layout` is URL-only state like `sorts`. Without it, opening a task
    // chat from a row-mode board and closing it snapped the board back to
    // column mode.
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      currentQuery: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
        layout: 'rows',
      },
    })
    expect(query.layout).toBe('rows')
  })

  it('omits ?layout= when the board is in the default column mode', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      currentQuery: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
    })
    expect(query.layout).toBeUndefined()
  })

  it('preserves an existing /chat/<taskId> suffix in the URL breadcrumb (re-navigation)', () => {
    // The URL already carries the chat suffix from a previous click. The new URL must keep that
    // suffix (not replace it with a new one for a different task that we don't know about — that's
    // a caller bug). The helper reads the bare item id from the URL.
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      currentQuery: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${ITEM_ID}/chat/task_old`,
        sorts: 'col_a:name:asc',
      },
    })
    expect(query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
  })

  it('prefers active store state over URL breadcrumb when both exist', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: 'ws_b',
      activeWorkspaceItemId: 'kanban_b',
      currentQuery: {
        view: 'workspace',
        workspaceId: 'ws_a',
        itemId: 'kanban_a',
      },
    })
    expect(query.workspaceId).toBe('ws_b')
    expect(query.itemId).toBe(`kanban_b/chat/${TASK_ID}`)
  })

  it('drops the redundant session query param (session == taskId under the new shape)', () => {
    // Pre-2026-08-15: `session` was emitted alongside `task`. The new
    // wire shape encodes the task id in the itemId suffix, so `session`
    // would be redundant. The helper must NOT emit it.
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      sessionId: TASK_ID, // back-compat — callers may still pass it
      activeWorkspaceId: WS_ID,
      activeWorkspaceItemId: ITEM_ID,
    })
    expect(query.session).toBeUndefined()
    expect((query as Record<string, unknown>).session).toBeUndefined()
  })

  it('handles empty-string active ids as "no active context" (falls back to URL)', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: '',
      activeWorkspaceItemId: '',
      currentQuery: {
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
    })
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
  })

  it('handles null active ids as "no active context" (falls back to URL)', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: null,
      activeWorkspaceItemId: null,
      currentQuery: {
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
    })
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
  })

  it('trims whitespace from active ids (defensive)', () => {
    const query = buildTaskUrlQuery({
      taskId: TASK_ID,
      activeWorkspaceId: '  ws_a  ',
      activeWorkspaceItemId: '  item_kanban  ',
    })
    expect(query.workspaceId).toBe('ws_a')
    expect(query.itemId).toBe('item_kanban/chat/task_1')
  })

  it('throws if the activeWorkspaceItemId contains /chat/ (defensive)', () => {
    // Defensive: if a caller passes a wire-shape item id by mistake,
    // the helper must NOT silently corrupt the URL. It throws.
    expect(() =>
      buildTaskUrlQuery({
        taskId: TASK_ID,
        activeWorkspaceId: WS_ID,
        activeWorkspaceItemId: `${ITEM_ID}/chat/task_other`,
      }),
    ).toThrow(/item id cannot contain/)
  })
})

describe('pickBreadcrumbFromQuery — extracts breadcrumb scalars', () => {
  it('picks workspaceId, itemId, pageId, sorts, layout when all are strings', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      pageId: 'page_x',
      sorts: 'col_a:name:asc',
      layout: 'rows',
      view: 'workspace', // not breadcrumb — ignored
    })
    expect(out).toEqual({
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      pageId: 'page_x',
      sorts: 'col_a:name:asc',
      layout: 'rows',
    })
  })

  it('preserves a /chat/<taskId> suffix on itemId (callers strip if they need the bare id)', () => {
    // The breadcrumb extraction is intentionally permissive — it
    // doesn't strip the /chat/ suffix because callers may want to
    // pass the wire value through (e.g. for re-navigation).
    const out = pickBreadcrumbFromQuery({
      workspaceId: WS_ID,
      itemId: `${ITEM_ID}/chat/${TASK_ID}`,
    })
    expect(out.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
  })

  it('skips empty strings (does NOT coalesce empty to undefined)', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: '',
      itemId: ITEM_ID,
    })
    expect(out.workspaceId).toBeUndefined()
    expect(out.itemId).toBe(ITEM_ID)
  })

  it('skips non-string values (null, arrays)', () => {
    const out = pickBreadcrumbFromQuery({
      workspaceId: null,
      itemId: ['item_a', 'item_b'] as unknown as string,
    })
    expect(out.workspaceId).toBeUndefined()
    expect(out.itemId).toBeUndefined()
  })

  it('returns empty object when no breadcrumb keys present', () => {
    const out = pickBreadcrumbFromQuery({
      view: 'chat',
      session: 'task_1',
    })
    expect(out).toEqual({})
  })
})

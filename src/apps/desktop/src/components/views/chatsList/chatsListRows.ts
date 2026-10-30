import type { Ref } from 'vue'
import { formatRelativeTime } from '../../../helpers/relativeTime'

export type ChatsNavItem = {
  id: string
  name: string
  active?: boolean
  relativeTime?: string
  selected_profile_model?: string
  sub_agent_name?: string
  parent_session_id?: string
  cwd?: string
  git_worktree_cwd?: string
  git_branch?: string
  is_auto_retry_until_stop?: string
  last_human_touched_at?: string
  updated_at?: string
  // Raw `updated_at` sort value (matches the backend
  // `sort_by=updated_at` order). Used for display sorting and for
  // cache-first scroll-back (`loadOlderFromCache`).
  sortKey?: string
  // Migration 104 — pinned sessions (PINNED section above RECENT).
  is_pinned?: boolean
  pinned_position?: number
  last_finish_reason?: string
  needs_human_review?: boolean
}

export interface ChatsRowsDeps {
  navItems: Ref<ChatsNavItem[]>
  chatsSortDirection: Ref<'asc' | 'desc'>
  scopedWorkspaceId: { readonly value: string | undefined }
}

export function useChatsRows(deps: ChatsRowsDeps) {
  const { navItems, chatsSortDirection, scopedWorkspaceId } = deps

  // Sidebar local-first: the cache partition key. Matches the
  // `scopedWorkspaceId` refetch boundary — each workspace paints its own
  // cached rows, `'all'` when unscoped (back-compat).
  const sessionCacheKey = (): string => scopedWorkspaceId.value ?? 'all'

  // Single mapper for server session → row view model, shared by the cache paint and the network paint
  // so both shapes stay identical (same "no shape drift" rule as ChatView's toChatMessages).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
  const toNavItem = (session: any) => ({
    id: session.session_id,
    name: session.session_name || 'New Chat',
    // active state now derives from the URL via isCurrentChat() in the template
    // (sidebar-single-active fix 2026-08-06). Storing it here would freeze the highlight at
    // loadChats() time and leave stale `active: true` after navigation away from chat.
    active: false,
    // Migration 082 — prefer human-touched timestamp when present.
    relativeTime: formatRelativeTime(session.last_human_touched_at || session.updated_at),
    selected_profile_model: session.selected_profile_model || '',
    sub_agent_name: session.sub_agent_name || '',
    parent_session_id: session.parent_session_id || '',
    cwd: session.cwd || '',
    git_worktree_cwd: session.git_worktree_cwd || '',
    git_branch: session.git_branch || '',
    // Migration 063 — defaulted to "0" in getChats mapping so the
    // `=== '1'` badge check below is well-defined.
    is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
    // Migration 082 — captured separately for the stale-dot check
    // (compares updated_at vs last_human_touched_at to render the
    // amber "AI is ahead of you" indicator).
    last_human_touched_at: session.last_human_touched_at || '',
    updated_at: session.updated_at || '',
    sortKey: session.updated_at || '',
    // Migration 104 — pinned sessions. Boolean on the wire; default
    // false so legacy caches read as unpinned.
    is_pinned: session.is_pinned ?? false,
    pinned_position: session.pinned_position ?? 0,
    last_finish_reason: session.last_finish_reason || '',
    // NOT `?? false`: a legacy cache row with no field must read as
    // "no badge", not "reviewed".
    needs_human_review: session.needs_human_review ?? undefined,
  })

  // Display order for cached paints. The engine stores newest-first;
  // the backend serves `direction` order — re-apply it here so a warm
  // mount in asc mode matches the network order exactly.
  const sortNavItemsForDisplay = () => {
    const asc = chatsSortDirection.value === 'asc'
    navItems.value.sort((a, b) => {
      const ak = a.sortKey ?? ''
      const bk = b.sortKey ?? ''
      if (ak === bk) return 0
      return (ak < bk ? -1 : 1) * (asc ? 1 : -1)
    })
  }

  // Minimal Chat shape for the cache write-through above.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const mapNavItemToChat = (r: any): any => ({
    session_id: r.id,
    session_name: r.name,
    cwd: r.cwd ?? '',
    git_worktree_cwd: r.git_worktree_cwd ?? '',
    git_branch: r.git_branch ?? '',
    updated_at: r.updated_at ?? '',
    selected_profile_model: r.selected_profile_model ?? '',
    is_auto_retry_until_stop: r.is_auto_retry_until_stop ?? '0',
    last_human_touched_at: r.last_human_touched_at ?? '',
    is_pinned: r.is_pinned ?? false,
    pinned_position: r.pinned_position ?? 0,
    last_finish_reason: r.last_finish_reason ?? '',
    needs_human_review: r.needs_human_review ?? undefined,
  })

  return { sessionCacheKey, toNavItem, sortNavItemsForDisplay, mapNavItemToChat }
}

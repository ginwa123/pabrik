<template>
  <!--
    Workspace folder preview — the "no item selected, pick one"
    empty-state. Only renders when the user has navigated to
    `?view=workspace` AND has no active workspace item. If an
    item is active (kanban / design / folder with memories /
    etc.), the dedicated branch above handles rendering; we
    MUST NOT also render the preview or the user sees the
    workspace name duplicated below the dedicated view
    (regression confirmed by the user's screenshot on
    2026-08-06 after the kanban-chat-as-dialog plan removed a
    stale secondary <KanbanView> mount that was previously
    acting as an implicit guard).

    The `!activeWorkspaceItem` guard ensures mutual exclusivity
    with the dedicated branches above. Without it, the chain
    would still resolve to this branch when currentView is
    'workspace' even if a kanban/design is active, because
    the kanban + dialog + chat-view mounts live in different
    v-if chains (they were refactored to mount in their own
    chains during the kanban-embed-chatview plan).
  -->
  <div class="flex-1 flex flex-col" data-testid="workspace-folder-preview">
    <!--
      The three inner branches (memories view / no-path
      centered card / workspaces picker) only ever need to
      render when there IS no active workspace item — the
      outer v-if already guarantees that. The inner branches
      previously referenced `activeWorkspaceItem` defensively
      for type narrowing; we keep them as-is but rely on the
      outer guard so the inner conditions don't need to
      re-check. Vue's template type-checker can't infer the
      type from `v-if` short-circuit across nested v-if/v-else
      chains, so the inner conditions stay as they were. This
      is a no-op at runtime since `activeWorkspaceItem` is
      always null here.
    -->
  </div>
</template>

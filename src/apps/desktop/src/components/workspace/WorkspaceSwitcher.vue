<script setup lang="ts">
/** WorkspaceSwitcher — header dropdown for selecting the active workspace. */
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type { Workspace } from '../../stores/workspaces'
import type { WorkspaceInvitation } from '../../api'
import OpenInNewTabMenu from '../shell/OpenInNewTabMenu.vue'
import { useContextMenu } from '../../composables/useContextMenu'
import { isBackgroundOpenEvent } from '../../helpers/tabTarget'

const props = withDefaults(
  defineProps<{
    workspaces: Workspace[]
    activeWorkspaceId?: string | null
    /**      * Collapsed-sidebar mode: monogram trigger + the panel is teleported to <body> (fixed position)
     * so it escapes the narrow sidebar's overflow. */
    collapsed?: boolean
    /** Pending invitations addressed to the signed-in account. Rendered only
     * when non-empty: an "Invitations" heading with nothing under it is noise. */
    invitations?: WorkspaceInvitation[]
  }>(),
  { activeWorkspaceId: null, collapsed: false, invitations: () => [] },
)

const emit = defineEmits<{
  select: [workspaceId: string]
  openWorkspaceInBackground: [workspaceId: string]
  addWorkspace: []
  renameWorkspace: [workspaceId: string, currentName: string]
  deleteWorkspace: [workspaceId: string]
  /** The invitee said yes — NOT the same as adding a workspace. */
  acceptInvitation: [invitationId: string]
  declineInvitation: [invitationId: string]
}>()

const open = ref(false)
/** Index into `workspaces` for keyboard navigation (-1 = none). */
const activeIndex = ref(-1)
const rootRef = ref<HTMLElement | null>(null)
/** The dropdown panel — in collapsed mode it is teleported to
 *  <body>, so outside-click detection must accept it separately. */
const panelRef = ref<HTMLElement | null>(null)

const activeWorkspace = computed(
  () => props.workspaces.find((ws) => ws.id === props.activeWorkspaceId) ?? null,
)
const triggerLabel = computed(() => activeWorkspace.value?.name ?? 'Select workspace')

/**  * 1–2 letter monogram for the collapsed trigger (algorithm moved from Sidebar's removed workspace
 * tiles — keep in sync with the old workspaceMonogram contract). */
const monogram = (name: string): string => {
  const cleaned = name.replace(/[^a-zA-Z0-9]/g, '')
  if (cleaned.length === 0) return '?'
  const head = cleaned[0]?.toUpperCase() ?? '?'
  if (cleaned.length < 2) return head
  for (let i = 1; i < Math.min(name.length, 6); i++) {
    const ch = name[i]
    const prev = name[i - 1]
    if (ch && /[a-zA-Z0-9]/.test(ch) && prev && /[^a-zA-Z0-9]/.test(prev)) {
      return head + ch.toUpperCase()
    }
  }
  return head
}
const triggerMonogram = computed(() => monogram(activeWorkspace.value?.name ?? '?'))

const openPanel = () => {
  const currentIdx = props.workspaces.findIndex((ws) => ws.id === props.activeWorkspaceId)
  activeIndex.value = currentIdx >= 0 ? currentIdx : props.workspaces.length > 0 ? 0 : -1
  open.value = true
}

const close = () => {
  open.value = false
  activeIndex.value = -1
}

const toggleOpen = () => {
  if (open.value) close()
  else openPanel()
}

const chooseOption = (workspaceId: string, event?: MouseEvent) => {
  // Ctrl/Cmd+click or middle-click opens the workspace in a new
  // browser tab and leaves the dropdown open state to close without
  // navigating the current tab.
  if (event && isBackgroundOpenEvent(event)) {
    emit('openWorkspaceInBackground', workspaceId)
    close()
    return
  }
  emit('select', workspaceId)
  close()
}

// Right-click "Open in new tab" on a workspace option. The payload
// is just the workspace id — Sidebar builds the workspace URL.
const { menuPos, openAt, close: closeWorkspaceMenu } = useContextMenu()
const contextMenuWorkspaceId = ref<string | null>(null)

const onWorkspaceOptionContextMenu = (event: MouseEvent, workspaceId: string) => {
  contextMenuWorkspaceId.value = workspaceId
  openAt(event)
}

const onWorkspaceOptionAuxClick = (event: MouseEvent, workspaceId: string) => {
  if (event.button !== 1) return
  event.preventDefault()
  emit('openWorkspaceInBackground', workspaceId)
  close()
}

const openWorkspaceMenuInBackground = () => {
  const id = contextMenuWorkspaceId.value
  contextMenuWorkspaceId.value = null
  closeWorkspaceMenu()
  if (!id) return
  emit('openWorkspaceInBackground', id)
  close()
}

const startRename = (ws: Workspace) => {
  emit('renameWorkspace', ws.id, ws.name)
  close()
}

const startDelete = (ws: Workspace) => {
  emit('deleteWorkspace', ws.id)
  close()
}

const startCreate = () => {
  emit('addWorkspace')
  close()
}

/** Wrap-around cursor movement over `workspaces`. */
const move = (delta: number) => {
  const n = props.workspaces.length
  if (n === 0) return
  const base = activeIndex.value
  activeIndex.value = base < 0 ? (delta > 0 ? 0 : n - 1) : (base + delta + n) % n
}

const commitActive = () => {
  const ws = props.workspaces[activeIndex.value]
  if (ws) chooseOption(ws.id)
}

const onTriggerKeydown = (event: KeyboardEvent) => {
  if (!open.value) {
    if (
      event.key === 'Enter' ||
      event.key === ' ' ||
      event.key === 'ArrowDown' ||
      event.key === 'ArrowUp'
    ) {
      event.preventDefault()
      openPanel()
    }
    return
  }
  if (event.key === 'ArrowDown') {
    event.preventDefault()
    move(1)
  } else if (event.key === 'ArrowUp') {
    event.preventDefault()
    move(-1)
  } else if (event.key === 'Enter') {
    event.preventDefault()
    commitActive()
  } else if (event.key === 'Escape') {
    event.preventDefault()
    close()
  }
}

/** mousedown (not click) so outside-press closes before focus juggling. */
const onDocumentMouseDown = (event: MouseEvent) => {
  if (!open.value) return
  const target = event.target as Node | null
  if (!target) return
  // The panel lives inside rootRef when expanded, but is teleported
  // to <body> when collapsed — accept either container.
  if (rootRef.value?.contains(target) || panelRef.value?.contains(target)) return
  close()
}

onMounted(() => document.addEventListener('mousedown', onDocumentMouseDown))
onBeforeUnmount(() => document.removeEventListener('mousedown', onDocumentMouseDown))
</script>

<template>
  <div ref="rootRef" class="relative min-w-0" data-testid="workspace-switcher">
    <button
      type="button"
      class="max-w-[180px] inline-flex items-center gap-1.5 text-dense font-semibold tracking-tight transition-opacity duration-150 hover:opacity-80"
      style="color: var(--semantic-text)"
      :title="`Workspace: ${triggerLabel}`"
      aria-haspopup="listbox"
      :aria-expanded="open"
      aria-label="Select workspace"
      data-testid="workspace-switcher-trigger"
      @click.stop="toggleOpen"
      @keydown="onTriggerKeydown"
    >
      <template v-if="collapsed">
        <span
          class="w-[var(--sb-hit)] h-[var(--sb-hit)] rounded-md flex items-center justify-center text-dense font-semibold tracking-tight border"
          style="border-color: var(--color-border); color: var(--semantic-text)"
          data-testid="workspace-switcher-monogram"
          >{{ triggerMonogram }}</span
        >
      </template>
      <template v-else>
        <span class="truncate">{{ triggerLabel }}</span>
        <span
          class="text-meta shrink-0"
          style="color: var(--semantic-text-dim)"
          aria-hidden="true"
          >▾</span
        >
      </template>
    </button>

    <Teleport to="body" :disabled="!collapsed">
      <div
        v-if="open"
        ref="panelRef"
        role="listbox"
        aria-label="Workspaces"
        class="rounded-lg shadow-lg z-50 overflow-hidden"
        :class="
          collapsed
            ? 'fixed top-14 left-3 w-[260px]'
            : 'absolute top-full left-0 mt-1 w-[260px] max-w-[80vw]'
        "
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        data-testid="workspace-switcher-panel"
        @click.stop
      >
        <div class="max-h-[320px] overflow-y-auto py-1">
          <!-- An invitation is a request, not a workspace: it sits above the
               list because answering it is what puts a row in that list. -->
          <div
            v-if="invitations.length"
            data-testid="workspace-switcher-invitations"
            class="pb-1 mb-1"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <p
              class="px-3 pt-1 pb-1 text-micro uppercase tracking-wide"
              style="color: var(--semantic-text-dim)"
            >
              Invitations
            </p>
            <div
              v-for="invitation in invitations"
              :key="invitation.id"
              class="px-3 py-1.5 flex items-center gap-2"
              :data-testid="`workspace-switcher-invitation-${invitation.id}`"
            >
              <span class="flex-1 min-w-0 text-dense truncate" style="color: var(--semantic-text)">
                {{ invitation.workspace_name || invitation.workspace_id }}
              </span>
              <button
                type="button"
                class="px-2 h-6 rounded-md text-micro font-medium border transition-opacity duration-150 hover:opacity-80"
                style="border-color: var(--color-green); color: var(--color-green)"
                :data-testid="`workspace-switcher-invitation-accept-${invitation.id}`"
                @click.stop="emit('acceptInvitation', invitation.id)"
              >
                Accept
              </button>
              <button
                type="button"
                class="px-2 h-6 rounded-md text-micro transition-opacity duration-150 opacity-70 hover:opacity-100"
                style="color: var(--semantic-text-dim)"
                :data-testid="`workspace-switcher-invitation-decline-${invitation.id}`"
                @click.stop="emit('declineInvitation', invitation.id)"
              >
                Decline
              </button>
            </div>
          </div>

          <div
            v-for="(ws, idx) in workspaces"
            :key="ws.id"
            class="group/ws relative flex items-center"
            :style="{
              backgroundColor: idx === activeIndex ? 'var(--semantic-sidebar-bg)' : 'transparent',
            }"
          >
            <button
              type="button"
              class="flex-1 min-w-0 text-left px-3 py-2 text-dense hover:opacity-90 flex items-center justify-between gap-2"
              style="color: var(--semantic-text)"
              :aria-selected="ws.id === activeWorkspaceId"
              :data-testid="`workspace-switcher-option-${ws.id}`"
              @click="chooseOption(ws.id, $event)"
              @auxclick="onWorkspaceOptionAuxClick($event, ws.id)"
              @contextmenu.prevent="onWorkspaceOptionContextMenu($event, ws.id)"
            >
              <span class="truncate">{{ ws.name }}</span>
              <span class="flex items-center gap-2 shrink-0">
                <span class="text-micro" style="color: var(--semantic-text-dim)">{{
                  ws.items_count ?? ws.items?.length ?? 0
                }}</span>
                <span
                  v-if="ws.id === activeWorkspaceId"
                  data-testid="workspace-switcher-active-check"
                  >✓</span
                >
              </span>
            </button>
            <button
              type="button"
              class="px-1.5 py-1 text-dense opacity-60 hover:opacity-100 focus-visible:opacity-100 transition-opacity"
              style="color: var(--semantic-text-dim)"
              title="Rename workspace"
              :aria-label="`Rename workspace ${ws.name}`"
              :data-testid="`workspace-switcher-rename-${ws.id}`"
              @click.stop="startRename(ws)"
            >
              ✎
            </button>
            <button
              type="button"
              class="px-1.5 py-1 text-dense opacity-60 hover:opacity-100 focus-visible:opacity-100 transition-opacity"
              style="color: var(--semantic-text-dim)"
              title="Delete workspace"
              :aria-label="`Delete workspace ${ws.name}`"
              :data-testid="`workspace-switcher-delete-${ws.id}`"
              @click.stop="startDelete(ws)"
            >
              ×
            </button>
          </div>

          <div
            v-if="workspaces.length === 0"
            class="px-3 py-2 text-dense"
            style="color: var(--semantic-text-muted)"
            data-testid="workspace-switcher-empty"
          >
            No workspaces yet.
          </div>
        </div>

        <button
          type="button"
          class="w-full text-left px-3 py-2 text-dense hover:opacity-80"
          style="color: var(--semantic-text-dim); border-top: 1px solid var(--color-border)"
          data-testid="workspace-switcher-add-workspace"
          @click="startCreate"
        >
          + New workspace
        </button>
      </div>
    </Teleport>
    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      open-label="Open in new tab"
      @open="openWorkspaceMenuInBackground"
    />
  </div>
</template>

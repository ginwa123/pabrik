import { onMounted, onUnmounted } from 'vue'
import type { ComputedRef, Ref } from 'vue'
import type { DesignElement as DesignElementApi } from '../../api'
import type { useDesignContextMenu } from '../../composables/useDesignContextMenu'
import type { useDesignHandlers } from '../../composables/useDesignHandlers'
import type { useDesignHistory } from '../../composables/useDesignHistory'
import { useWorkspacesStore } from '../../stores/workspaces'

export type ReorderMode = 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'

type Deps = {
  workspaceId: ComputedRef<string>
  effectiveItemId: ComputedRef<string>
  activePageId: ComputedRef<string>
  elements: ComputedRef<DesignElementApi[]>
  selectedIds: Ref<Set<string>>
  nudgeOffsets: Map<string, { x: number; y: number }>
  isPreviewMode: Ref<boolean>
  togglePreviewMode: () => void
  isSpacePressed: Ref<boolean>
  showAddElementDialog: Ref<boolean>
  zoomFit: () => void
  dispatchReorder: (mode: ReorderMode) => Promise<void>
  designHandlers: ReturnType<typeof useDesignHandlers>
  history: ReturnType<typeof useDesignHistory>
  contextMenu: ReturnType<typeof useDesignContextMenu>
}

export function useDesignKeyboard(deps: Deps): void {
  const {
    workspaceId,
    effectiveItemId,
    activePageId,
    elements,
    selectedIds,
    nudgeOffsets,
    isPreviewMode,
    togglePreviewMode,
    isSpacePressed,
    showAddElementDialog,
    zoomFit,
    dispatchReorder,
    designHandlers,
    history,
    contextMenu,
  } = deps
  const workspacesStore = useWorkspacesStore()

  const handleKeydown = (event: KeyboardEvent): void => {
    // Skip when the user is typing in an input/textarea/contenteditable
    // — don't steal keys from the W×H inputs, the PropertiesPanel
    // form fields, etc.
    const target = event.target as HTMLElement | null
    if (
      target &&
      (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)
    ) {
      return
    }

    // Space held (no Ctrl/Cmd/Alt/Shift — those are bound to other shortcuts, and Alt+Space is the
    // window-menu shortcut on Linux/macOS). Plain Space should NOT scroll the page when the design
    // view is mounted — that's the browser default we override here.
    if (event.key === ' ' && !event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey) {
      if (!isSpacePressed.value) {
        isSpacePressed.value = true
        document.body.style.cursor = 'grab'
      }
      event.preventDefault()
      return
    }

    if (event.key === 'Escape') {
      // Esc exits Preview first (more useful than clearing selection
      // — the user is trying to get back to editing). Only clear the
      // selection if we're already in Edit mode.
      if (isPreviewMode.value) {
        togglePreviewMode()
        return
      }
      selectedIds.value = new Set()
      // Also close the canvas context menu (Chunk 4) and the
      // add-element dialog if it's open.
      contextMenu.close()
      if (showAddElementDialog.value) {
        showAddElementDialog.value = false
      }
      return
    }

    // Chunk 4: Cmd/Ctrl+A → Select all (Figma convention).
    // Handles BOTH Mac (metaKey) and Linux/Windows (ctrlKey).
    if (
      (event.key === 'a' || event.key === 'A') &&
      (event.ctrlKey || event.metaKey) &&
      !event.shiftKey &&
      !event.altKey
    ) {
      event.preventDefault()
      selectedIds.value = new Set(elements.value.map((e) => e.id))
      return
    }

    // Chunk 4: Cmd/Ctrl+] (bring forward) and Cmd/Ctrl+Shift+] (bring to front). Both gate on
    // selection.size >= 1. The actual reorder call lives in `workspacesStore.reorderDesignElements`,
    // which Chunk 5 introduces — until then the shortcut fires the stub that no-ops with a warning.
    if (event.key === ']' && (event.ctrlKey || event.metaKey) && !event.altKey) {
      event.preventDefault()
      if (event.shiftKey) {
        void dispatchReorder('bring_to_front')
      } else {
        void dispatchReorder('bring_forward')
      }
      return
    }

    // Chunk 4: Cmd/Ctrl+[ (send backward) and Cmd/Ctrl+Shift+[
    // (send to back).
    if (event.key === '[' && (event.ctrlKey || event.metaKey) && !event.altKey) {
      event.preventDefault()
      if (event.shiftKey) {
        void dispatchReorder('send_to_back')
      } else {
        void dispatchReorder('send_backward')
      }
      return
    }

    // Chunk 4: Backspace / Delete → delete current selection.
    if (
      (event.key === 'Backspace' || event.key === 'Delete') &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey &&
      !event.shiftKey
    ) {
      event.preventDefault()
      if (selectedIds.value.size === 0) return
      const count = selectedIds.value.size
      if (!confirm(`Delete ${count} element${count === 1 ? '' : 's'}?`)) return
      if (!workspaceId.value || !effectiveItemId.value || !activePageId.value) return
      // Undo/redo plan (Chunk 5): capture deleted elements + their
      // HTML bodies BEFORE the deletion so undo restores them.
      const deletedElements = Array.from(selectedIds.value)
        .map((id) => {
          const el = elements.value.find((e) => e.id === id)
          if (!el) return null
          return { element: { ...el }, htmlBody: null as string | null }
        })
        .filter((e): e is { element: DesignElementApi; htmlBody: string | null } => e !== null)
      void history.captureDelete(deletedElements)
      for (const id of Array.from(selectedIds.value)) {
        void workspacesStore.deleteDesignElement(
          workspaceId.value,
          effectiveItemId.value,
          activePageId.value,
          id,
        )
      }
      selectedIds.value = new Set()
      return
    }

    // Cmd/Ctrl+P toggles Preview/Edit mode. Plain P (no modifier) is a common type-to-pan shortcut in
    // design tools — not used here, but we intentionally don't bind it so the future pan-tool doesn't
    // conflict.
    if (
      (event.key === 'p' || event.key === 'P') &&
      (event.ctrlKey || event.metaKey) &&
      !event.shiftKey &&
      !event.altKey
    ) {
      event.preventDefault()
      togglePreviewMode()
      return
    }

    // NEW (Chunk 6 of grouped-layers plan): Cmd/Ctrl+G groups the current selection into a new
    // `group` at the union bbox. Figma convention. The composable enforces the 2+ selection rule
    // silently (mirrors Figma's Cmd+G).
    if (
      (event.key === 'g' || event.key === 'G') &&
      (event.ctrlKey || event.metaKey) &&
      !event.altKey
    ) {
      event.preventDefault()
      if (event.shiftKey) {
        if (selectedIds.value.size === 1) {
          const onlyId = Array.from(selectedIds.value)[0]
          if (onlyId) void designHandlers.ungroupSelection(onlyId)
        }
        return
      }
      // Undo/redo plan (Chunk 5): capture the group entry before
      // the selection gets cleared by the composable.
      void history.captureGroup('__pending__', Array.from(selectedIds.value), true)
      void designHandlers.groupSelection()
      return
    }

    // Undo/redo keyboard shortcuts (Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z, Cmd/Ctrl+Y) were intentionally
    // removed in 2026-08-06 when the feature was hidden from the design UI. Browser-native Cmd+Z now
    // reaches the user unimpeded.
    if (
      (event.key === 'f' || event.key === 'F' || (event.key === '1' && event.shiftKey)) &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey
    ) {
      event.preventDefault()
      zoomFit()
    }

    // Arrow keys nudge the selection by 1 design-px; Shift+arrow by 10.
    // Gated on `selectedIds.size > 0` (Figma-style: arrows do nothing
    // when there's nothing to nudge).
    if (
      selectedIds.value.size > 0 &&
      (event.key === 'ArrowLeft' ||
        event.key === 'ArrowRight' ||
        event.key === 'ArrowUp' ||
        event.key === 'ArrowDown')
    ) {
      event.preventDefault()
      const step = event.shiftKey ? 10 : 1
      const dx = event.key === 'ArrowLeft' ? -step : event.key === 'ArrowRight' ? step : 0
      const dy = event.key === 'ArrowUp' ? -step : event.key === 'ArrowDown' ? step : 0
      // Undo/redo plan (Chunk 4): each keypress is one undo entry (Figma parity). Pre-state is
      // captured BEFORE the PATCH loop; post-state AFTER. capturePostState is async (reads HTML
      // body); we don't await so the next keypress queues the next capture.
      void history.capturePreState(Array.from(selectedIds.value))
      for (const id of selectedIds.value) {
        const el = elements.value.find((e) => e.id === id)
        if (!el) continue
        // The element's "effective" position is the cached `el.x` plus the accumulated nudge delta
        // (since the last time `elements.value` was fresh). Without this, the second arrow press
        // would read the stale `el.x` and re-emit the same x, freezing the element.
        const off = nudgeOffsets.get(id) ?? { x: 0, y: 0 }
        const baseX = el.x + off.x
        const baseY = el.y + off.y
        const newX = baseX + dx
        const newY = baseY + dy
        nudgeOffsets.set(id, { x: newX - el.x, y: newY - el.y })
        void workspacesStore.updateDesignElementGeometry(
          workspaceId.value,
          effectiveItemId.value,
          activePageId.value,
          id,
          { x: newX, y: newY },
        )
      }
      void history.capturePostState(Array.from(selectedIds.value))
      return
    }
  }

  const handleKeyup = (event: KeyboardEvent): void => {
    // Release Space. Don't gate on target — if focus moved to an input
    // mid-press, we still want to clear the body cursor on Space-up.
    if (event.key === ' ' && isSpacePressed.value) {
      isSpacePressed.value = false
      document.body.style.cursor = ''
    }
  }

  const handleWindowBlur = (): void => {
    // Defensive: if focus is lost (window blur / tab switch) while
    // Space is held, the keyup event may never fire. Reset so we
    // don't leave the cursor stuck on "grab".
    if (isSpacePressed.value) {
      isSpacePressed.value = false
      document.body.style.cursor = ''
    }
  }

  onMounted(() => {
    document.addEventListener('keydown', handleKeydown)
    document.addEventListener('keyup', handleKeyup)
    window.addEventListener('blur', handleWindowBlur)
  })

  onUnmounted(() => {
    document.removeEventListener('keydown', handleKeydown)
    document.removeEventListener('keyup', handleKeyup)
    window.removeEventListener('blur', handleWindowBlur)
    // Defensive: clear body cursor if we unmount mid-press.
    document.body.style.cursor = ''
    // NOTE: we intentionally do NOT clear `activeDesignPageId` here. Why: AppLayout's main-content
    // v-else-if chain renders TWO <DesignView> instances for the same design item — one in the
    // single-column branch (no chat open) and one inside the 3-column branch (chat open).
  })
}

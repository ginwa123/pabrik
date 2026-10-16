import { computed, onBeforeUnmount, onMounted, ref } from 'vue'

export interface ContextMenuState {
  visible: boolean
  x: number
  y: number
  targetIds: string[]
}

/** Drives a Teleport-based right-click menu (used by both the design layers panel and the design
 * canvas). Owns the open/close lifecycle and the document-level listeners that dismiss the menu on
 * click-outside, Escape, window resize, or scroll. */
export function useDesignContextMenu() {
  const state = ref<ContextMenuState>({
    visible: false,
    x: 0,
    y: 0,
    targetIds: [],
  })

  function open(event: MouseEvent, targetIds: string[]): void {
    event.preventDefault()
    state.value = {
      visible: true,
      x: event.clientX,
      y: event.clientY,
      targetIds: [...targetIds],
    }
  }

  function close(): void {
    state.value = { visible: false, x: 0, y: 0, targetIds: [] }
  }

  function handleDocumentClick(): void {
    if (state.value.visible) close()
  }

  function handleDocumentKeydown(event: KeyboardEvent): void {
    if (state.value.visible && event.key === 'Escape') close()
  }

  function handleWindowResize(): void {
    if (state.value.visible) close()
  }

  function handleWindowScroll(): void {
    if (state.value.visible) close()
  }

  onMounted(() => {
    document.addEventListener('click', handleDocumentClick)
    document.addEventListener('keydown', handleDocumentKeydown)
    window.addEventListener('resize', handleWindowResize)
    // Capture phase so we catch scroll inside any overflow container
    // (e.g. the layers panel) before the scroll bubbles up.
    window.addEventListener('scroll', handleWindowScroll, true)
  })

  onBeforeUnmount(() => {
    document.removeEventListener('click', handleDocumentClick)
    document.removeEventListener('keydown', handleDocumentKeydown)
    window.removeEventListener('resize', handleWindowResize)
    window.removeEventListener('scroll', handleWindowScroll, true)
  })

  return {
    open,
    close,
    state: computed(() => state.value),
  }
}
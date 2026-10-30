import { ref } from 'vue'
import { SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_WIDTH } from './designViewStorage'

type Deps = {
  readSidebarWidth: () => number
  writeSidebarWidth: (n: number) => void
  readLayersHeightRatio: () => number
  writeLayersHeightRatio: (n: number) => void
}

export function useDesignPanelResize(deps: Deps) {
  const { readSidebarWidth, writeSidebarWidth, readLayersHeightRatio, writeLayersHeightRatio } = deps

  // ─── Right sidebar width (drag-resize handle) ──────────────────────────
  const sidebarWidth = ref<number>(readSidebarWidth())
  const isSidebarResizing = ref(false)

  const startSidebarResize = (event: MouseEvent): void => {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = sidebarWidth.value
    isSidebarResizing.value = true
    document.body.style.cursor = 'col-resize'
    document.body.style.userSelect = 'none'

    const onMove = (e: MouseEvent): void => {
      const dx = startX - e.clientX
      const next = Math.max(SIDEBAR_MIN_WIDTH, Math.min(SIDEBAR_MAX_WIDTH, startWidth + dx))
      sidebarWidth.value = next
    }
    const onUp = (): void => {
      isSidebarResizing.value = false
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      writeSidebarWidth(sidebarWidth.value)
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
    }
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  }

  // ─── Vertical split between Layers and Properties (within sidebar) ─────
  const layersHeightRatio = ref<number>(readLayersHeightRatio())
  const isLayersResizing = ref(false)

  const startLayersResize = (event: MouseEvent): void => {
    event.preventDefault()
    const sidebarEl = (event.currentTarget as HTMLElement | null)?.parentElement
    if (!sidebarEl) return
    const startY = event.clientY
    const startRatio = layersHeightRatio.value
    const sidebarHeight = sidebarEl.getBoundingClientRect().height
    isLayersResizing.value = true
    document.body.style.cursor = 'row-resize'
    document.body.style.userSelect = 'none'

    const onMove = (e: MouseEvent): void => {
      const dy = e.clientY - startY
      const ratio = startRatio + dy / sidebarHeight
      layersHeightRatio.value = Math.max(0.15, Math.min(0.7, ratio))
    }
    const onUp = (): void => {
      isLayersResizing.value = false
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
      writeLayersHeightRatio(layersHeightRatio.value)
      document.removeEventListener('mousemove', onMove)
      document.removeEventListener('mouseup', onUp)
    }
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', onUp)
  }

  return {
    sidebarWidth,
    isSidebarResizing,
    startSidebarResize,
    layersHeightRatio,
    isLayersResizing,
    startLayersResize,
  }
}

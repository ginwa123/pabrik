import { ref, type Ref } from 'vue'
import { useSidebarStore } from '../../stores/sidebar'

const MIN_SECTION_PX = 80

export function useProjectsResize(sectionRef: Ref<HTMLElement | null>) {
  const sidebarStore = useSidebarStore()
  const isResizing = ref(false)
  let startY = 0
  let startPx = 0

  const navHeightPx = (): number => sectionRef.value?.parentElement?.clientHeight ?? 0

  const onMove = (e: MouseEvent) => {
    if (!isResizing.value) return
    e.preventDefault()
    const navHeight = navHeightPx()
    if (navHeight <= 0) return
    const nextPx = Math.max(MIN_SECTION_PX, startPx + (e.clientY - startY))
    sidebarStore.setProjectsHeight((nextPx / navHeight) * 100)
  }

  const stopProjectsResize = () => {
    isResizing.value = false
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseup', stopProjectsResize)
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  const startProjectsResize = (e: MouseEvent) => {
    const section = sectionRef.value
    if (!section) return
    e.preventDefault()
    isResizing.value = true
    startY = e.clientY
    startPx = section.getBoundingClientRect().height
    document.addEventListener('mousemove', onMove)
    document.addEventListener('mouseup', stopProjectsResize)
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'row-resize'
  }

  const resetProjectsHeight = () => sidebarStore.setProjectsHeight(null)

  return { isResizing, startProjectsResize, stopProjectsResize, resetProjectsHeight }
}

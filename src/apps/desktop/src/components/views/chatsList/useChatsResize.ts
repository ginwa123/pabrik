import { ref } from 'vue'
import { useSidebarStore } from '../../../stores/sidebar'

export function useChatsResize() {
  const sidebarStore = useSidebarStore()

  // Chats resize handling
  const isChatsResizing = ref(false)
  const chatsResizeStartY = ref(0)
  const chatsResizeStartPx = ref(0)


  // Get computed chats height in pixels from percentage
  const getChatsHeightPx = (): number => {
    const aside = document.querySelector('aside')
    if (!aside) return 200
    const navHeight = aside.clientHeight - 56 - 48 // header + footer
    return (navHeight * sidebarStore.chatsHeight) / 100
  }

  const startChatsResize = (e: MouseEvent) => {
    e.preventDefault()
    e.stopPropagation()
    console.log('[ChatsList] startChatsResize', e.clientY)
    isChatsResizing.value = true
    chatsResizeStartY.value = e.clientY
    chatsResizeStartPx.value = getChatsHeightPx()
    document.addEventListener('mousemove', handleChatsResize, { passive: false })
    document.addEventListener('mouseup', stopChatsResize)
    document.body.style.userSelect = 'none'
    document.body.style.cursor = 'row-resize'
  }

  const handleChatsResize = (e: MouseEvent) => {
    e.preventDefault()
    if (!isChatsResizing.value) return
    console.log(
      '[ChatsList] handleChatsResize',
      e.clientY,
      'delta:',
      e.clientY - chatsResizeStartY.value,
    )
    const deltaY = e.clientY - chatsResizeStartY.value
    const newHeightPx = Math.max(80, chatsResizeStartPx.value + deltaY)
    // Convert back to percentage
    const aside = document.querySelector('aside')
    if (!aside) return
    const navHeight = aside.clientHeight - 56 - 48
    const newPercent = (newHeightPx / navHeight) * 100
    console.log('[ChatsList] newPercent:', newPercent)
    sidebarStore.setChatsHeight(newPercent)
  }

  const stopChatsResize = () => {
    isChatsResizing.value = false
    document.removeEventListener('mousemove', handleChatsResize)
    document.removeEventListener('mouseup', stopChatsResize)
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
  }

  return { isChatsResizing, startChatsResize, stopChatsResize }
}

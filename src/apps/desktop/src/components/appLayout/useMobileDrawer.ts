import { onMounted, onUnmounted } from 'vue'

export type MobileDrawerHost = {
  isOpen: () => boolean
  close: () => void
}

export type MobileDrawerRoute = {
  onNavigate: (listener: () => void) => () => void
}

export type MobileDrawerOptions = {
  host: MobileDrawerHost
  route: MobileDrawerRoute
  doc?: Document
}

export function useMobileDrawer(options: MobileDrawerOptions): void {
  const doc = options.doc ?? document

  const onKeydown = (event: KeyboardEvent) => {
    if (event.key !== 'Escape') return
    if (!options.host.isOpen()) return
    options.host.close()
  }

  onMounted(() => doc.addEventListener('keydown', onKeydown))
  onUnmounted(() => doc.removeEventListener('keydown', onKeydown))
  onUnmounted(options.route.onNavigate(() => options.host.close()))
}

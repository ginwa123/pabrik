import { onUnmounted } from 'vue'

export function useChatComposerInset() {
  // ─── Floating composer: the `--chat-composer-inset` contract ────────────────
  let chatColumnEl: HTMLElement | null = null
  const setChatColumnEl = (el: unknown) => {
    chatColumnEl = (el as HTMLElement | null) ?? null
  }

  let composerDockObserver: ResizeObserver | null = null
  const syncComposerInset = (height: number) => {
    // Ignore the 0×0 report a display:none dock emits (v-show hides it when the centre diff opens) — zeroing the inset there would make the last row lose its …
    if (height <= 0 || !chatColumnEl) return
    const px = `${Math.ceil(height)}px`
    if (chatColumnEl.style.getPropertyValue('--chat-composer-inset') === px) return
    chatColumnEl.style.setProperty('--chat-composer-inset', px)
  }
  const setComposerDockEl = (el: unknown) => {
    composerDockObserver?.disconnect()
    composerDockObserver = null
    const dockEl = (el as HTMLElement | null) ?? null
    if (!dockEl) return
    composerDockObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        syncComposerInset(entry.borderBoxSize?.[0]?.blockSize ?? entry.contentRect.height)
      }
    })
    composerDockObserver.observe(dockEl)
  }
  onUnmounted(() => {
    composerDockObserver?.disconnect()
    composerDockObserver = null
    chatColumnEl = null
  })

  return { setChatColumnEl, setComposerDockEl }
}

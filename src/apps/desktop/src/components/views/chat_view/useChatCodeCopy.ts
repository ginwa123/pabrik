import { nextTick, type Ref } from 'vue'
import { ICON_PATHS } from '../../ui/icons'
import type { VirtualScrollerExposed } from './chatViewTypes'

export interface ChatCodeCopyDeps {
  virtualScrollerRef: Ref<VirtualScrollerExposed | null>
  copyCodeContent: (codeContent: string) => void
}

export function useChatCodeCopy({ virtualScrollerRef, copyCodeContent }: ChatCodeCopyDeps) {
  const setupCodeBlockCopyButtons = () => {
    nextTick(() => {
      const container = virtualScrollerRef.value?.containerRef
      if (!container) return
      const codeBlocks = container.querySelectorAll('.markdown-content pre')
      codeBlocks.forEach((block) => {
        if (block.querySelector('.code-copy-btn')) return
        const code = block.querySelector('code')
        if (!code) return
        const content = code.textContent || ''
        const btn = document.createElement('button')
        btn.className = 'code-copy-btn'
        // Built imperatively (post-render decoration), so it cannot mount a
        // <UiIcon>; it renders the registry's own `clipboard` paths instead of
        // a hand-copied <path>, so the copy button stays on the one geometry.
        btn.innerHTML = `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICON_PATHS.clipboard.map((d) => `<path d="${d}"/>`).join('')}</svg>`
        btn.title = 'Copy code'
        btn.style.cssText =
          'position: absolute; top: 8px; right: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; border: none; background: var(--semantic-active-bg); border-radius: 4px; opacity: 0.7; transition: opacity 0.2s;'
        btn.onmouseover = () => (btn.style.opacity = '1')
        btn.onmouseout = () => (btn.style.opacity = '0.7')
        btn.onclick = (e) => {
          e.stopPropagation()
          copyCodeContent(content)
        }
        ;(block as HTMLElement).style.position = 'relative'
        block.appendChild(btn)
      })
    })
  }

  return { setupCodeBlockCopyButtons }
}

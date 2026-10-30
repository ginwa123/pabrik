import { computed, ref, type ComputedRef } from 'vue'
import type { ParsedDiffLine } from './parseUnifiedDiff'

interface MiniChatHost {
  path: string
}

/** The review mini-chat popup: its open/closed state, the anchor range it was opened at, the
 * viewport-clamped style, and the handlers that open/close it. Owned by the diff view that
 * renders the popup. */
export function useDiffMiniChat(props: MiniChatHost, displayLines: ComputedRef<ParsedDiffLine[]>) {
  const showMiniChat = ref(false)
  const miniChatPosition = ref({ x: 0, y: 0 })
  const miniChatContent = ref('')
  const miniChatFilePath = ref('')
  const miniChatStartLine = ref(0)
  const miniChatEndLine = ref(0)

  const miniChatStyle = computed(() => {
    const vw = typeof globalThis.window !== 'undefined' ? globalThis.window.innerWidth : 1280
    const vh = typeof globalThis.window !== 'undefined' ? globalThis.window.innerHeight : 800
    return {
      left: Math.min(miniChatPosition.value.x, vw - 420) + 'px',
      top: Math.min(miniChatPosition.value.y, vh - 300) + 'px',
      width: '400px',
      backgroundColor: 'var(--semantic-card-bg)',
      border: '1px solid var(--color-border)',
    }
  })

  const openBoxAtRange = (start: number, end: number, context: string) => {
    miniChatFilePath.value = props.path
    miniChatStartLine.value = start
    miniChatEndLine.value = end
    miniChatContent.value = context
    showMiniChat.value = true
  }

  /** Open the review box for the line at `lineIdx` in the rendered lines. */
  const openMiniChatAt = (event: MouseEvent, lineIdx: number) => {
    const lines = displayLines.value
    const line = lines[lineIdx]
    if (!line) return
    if (line.type !== 'add' && line.type !== 'remove') return
    event.preventDefault()
    event.stopPropagation()
    miniChatPosition.value = { x: event.clientX, y: event.clientY }
    const startIdx = Math.max(0, lineIdx - 3)
    const endIdx = Math.min(lines.length, lineIdx + 4)
    const contextLines = lines.slice(startIdx, endIdx)
    if (contextLines.length === 0) return
    const start = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
    const last = contextLines[contextLines.length - 1]!
    const end = last.newLineNum || last.oldLineNum || 0
    const content = contextLines
      .map((l) => {
        const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
        const lineNum = l.newLineNum || l.oldLineNum || ''
        return `${lineNum} ${prefix}${l.content}`
      })
      .join('\n')
    openBoxAtRange(start, end, content)
  }

  const openMiniChat = (event: MouseEvent, line: ParsedDiffLine) => {
    openMiniChatAt(event, displayLines.value.indexOf(line))
  }

  const onSplitComment = (payload: { event: MouseEvent; sourceIndex: number }) => {
    openMiniChatAt(payload.event, payload.sourceIndex)
  }

  const closeMiniChat = () => {
    showMiniChat.value = false
    miniChatContent.value = ''
    miniChatFilePath.value = ''
    miniChatStartLine.value = 0
    miniChatEndLine.value = 0
  }

  return {
    showMiniChat,
    miniChatContent,
    miniChatFilePath,
    miniChatStartLine,
    miniChatEndLine,
    miniChatStyle,
    openMiniChat,
    onSplitComment,
    closeMiniChat,
  }
}

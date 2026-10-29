/** Where the code viewer renders — ChatView's center column instead of a full-surface overlay
 * (kanban task_1790594549955_1, follow-up: "the right sidebar should be visible"). */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()
const appLayoutSrc = readFileSync(resolve(__dirname, '..', '..', 'AppLayout.vue'), 'utf8')

describe('ChatView — code viewer in the center column', () => {
  it('injects the open-file state AppLayout provides', () => {
    expect(chatViewSrc).toMatch(/const codeViewer = useInjectCodeViewer\(\)/)
    expect(chatViewSrc).toMatch(/const codeViewerFile|const codeViewerModel/)
    expect(chatViewSrc).toMatch(/import CodeViewerStage from '\.\/CodeViewerStage\.vue'/)
  })

  it('renders the stage in the center slot, beside the sidebar', () => {
    // The stage sits INSIDE the center column (the same parent as the
    // stacked diff and the messages), and the sidebar stays a sibling.
    const stageAt = chatViewSrc.indexOf('data-testid="chat-center-code"')
    const sidebarAt = chatViewSrc.indexOf('<ChatRightSidebar')
    expect(stageAt).toBeGreaterThan(-1)
    expect(sidebarAt).toBeGreaterThan(stageAt)
    expect(chatViewSrc).toMatch(/<ChatRightSidebar\s+v-if="!embedded"/)
  })

  it('hides messages and the composer while the viewer is up', () => {
    // One gate for both center stages — the composer can never float
    // over the file (the "composer visible under the viewer" report).
    expect(chatViewSrc).toMatch(
      /const showCenterStage = computed\(\(\) => showCenterDiff\.value \|\| showCodeViewer\.value\)/,
    )
    expect(chatViewSrc).toMatch(/v-show="!showCenterStage"\s+ref="messagesWrapperRef"/)
    expect(chatViewSrc).toMatch(/v-if="!hideInput"\s+v-show="!showCenterStage"/)
    expect(chatViewSrc).not.toMatch(/v-show="!showCenterDiff"/)
  })

  it('yields to the viewer over the diff stage (the diff opens files)', () => {
    expect(chatViewSrc).toMatch(/v-if="showCenterDiff && !showCodeViewer"/)
  })

  it('closes through AppLayout (one owner for session + URL)', () => {
    expect(chatViewSrc).toMatch(/@close="codeViewerModel\.close\(\)"/)
    expect(appLayoutSrc).toMatch(/close: closeCodeEditor,/)
  })

  it('renders nothing when no file is open (or no provider)', () => {
    expect(chatViewSrc).toMatch(
      /const showCodeViewer = computed\(\(\) => codeViewerModel\.value\.file !== null\)/,
    )
    expect(chatViewSrc).toMatch(/v-if="codeViewerModel\.file"/)
  })
})

describe('AppLayout — the overlay is only a fallback', () => {
  it('provides the shared state once, from the session refs', () => {
    expect(appLayoutSrc).toMatch(
      /provide<CodeViewerState>\(CODE_VIEWER_STATE_KEY, codeViewerState\)/,
    )
    // Same objects, no copies.
    expect(appLayoutSrc).toMatch(/file: codeEditorSession\.file,/)
    expect(appLayoutSrc).toMatch(/content: codeEditorSession\.content,/)
  })

  it('yields the whole <main> only when no chat surface is on screen', () => {
    expect(appLayoutSrc).toMatch(
      /if \(codeEditorFile\.value && !chatSurfaceActive\.value\) return 'code-editor'/,
    )
    // The predicate is the union of the chain's three chat branches and
    // excludes the design dialog + the chats list.
    expect(appLayoutSrc).toMatch(/const chatSurfaceActive = computed\(\(\) => \{/)
    expect(appLayoutSrc).toMatch(/if \(item\?\.item_type === 'design'\) return false/)
    expect(appLayoutSrc).toMatch(
      /if \(activeTask\.value && activeTaskWorkspaceItemId\.value === item\?\.id\) return true/,
    )
    expect(appLayoutSrc).toMatch(/return activeChatId\.value\.startsWith\('chat-'\)/)
  })

  it('renders the same stage component in the fallback overlay', () => {
    expect(appLayoutSrc).toMatch(/data-testid="code-viewer-overlay"/)
    expect(appLayoutSrc).toMatch(/<CodeViewerStage/)
  })
})

/** Static contract: ChatView opens sidebar files in the in-app code browser (which also updates the
 * app URL to view=code-editor). */
import { describe, expect, it } from 'vitest'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()

describe('ChatView sidebar open-file wiring', () => {
  it('handles open-file via the injected code-browser opener', () => {
    expect(chatViewSrc).toMatch(
      /function onChatSidebarOpenFile\(payload: \{ path: string; line\?: number \}\)/,
    )
    expect(chatViewSrc).toMatch(/const openInEditor = useInjectOpenInCodeEditor\(\)/)
    expect(chatViewSrc).toMatch(
      /void openInEditor\(\{ filePath: payload\.path, cwd: effectiveCwd\.value, line: payload\.line \}\)/,
    )
  })

  it('subscribes to the center diff open emit', () => {
    expect(chatViewSrc).toMatch(/@open="onChatSidebarOpenFile"/)
  })
})

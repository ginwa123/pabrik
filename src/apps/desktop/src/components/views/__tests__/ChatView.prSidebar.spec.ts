/** Static contract: ChatView feeds the session's attached-PR binding into the right sidebar so the
 * panel flips to PR-changes mode. */
import { describe, expect, it } from 'vitest'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()

describe('ChatView PR sidebar wiring', () => {
  it('holds the attached-PR binding in refs', () => {
    expect(chatViewSrc).toMatch(/const chatPrUrl = ref\(''\)/)
    expect(chatViewSrc).toMatch(/const chatPrProvider = ref\(''\)/)
  })

  it('loads the binding at mount and re-syncs on refresh', () => {
    expect(chatViewSrc).toMatch(/if \(data\.pr_url !== undefined\)/)
    expect(chatViewSrc).toMatch(/chatPrUrl\.value = data\.pr_url \?\? ''/)
    expect(chatViewSrc).toMatch(/chatPrProvider\.value = data\.pr_provider \?\? ''/)
  })

  it('re-syncs on set_pull_request SSE completions', () => {
    expect(chatViewSrc).toMatch(/toolName === 'set_pull_request'/)
  })

  it('passes the binding to the sidebar', () => {
    expect(chatViewSrc).toMatch(/:pr-url="chatPrUrl"/)
    expect(chatViewSrc).toMatch(/:pr-provider="chatPrProvider"/)
  })
})

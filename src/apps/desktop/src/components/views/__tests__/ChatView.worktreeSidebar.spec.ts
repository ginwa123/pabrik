/** Static contract: the ChatView-embedded git-diff sidebar must follow the session's worktree
 * binding, not the session's original cwd. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()
const panelSrc = readFileSync(
  resolve(__dirname, '../chat_right_sidebar/SidebarDiffPanel.vue'),
  'utf8',
)
const shellSrc = readFileSync(
  resolve(__dirname, '../chat_right_sidebar/ChatRightSidebar.vue'),
  'utf8',
)

describe('ChatView worktree sidebar binding', () => {
  it('refreshWorktreeBinding re-reads git_worktree_cwd via getSession (detail endpoint)', () => {
    expect(chatViewSrc).toMatch(/async function refreshWorktreeBinding\(\)/)
    expect(chatViewSrc).toMatch(/getSession\(sessionId\.value\)/)
    expect(chatViewSrc).toMatch(/data\.git_worktree_cwd !== undefined/)
    expect(chatViewSrc).toMatch(/gitWorktreeCwd\.value = data\.git_worktree_cwd/)
  })

  it('both SSE full-event paths hook set_git_worktree completions', () => {
    // Helper exists and gates on the tool name…
    expect(chatViewSrc).toMatch(/function maybeRefreshWorktreeBinding\(/)
    expect(chatViewSrc).toMatch(/toolName === 'set_git_worktree'/)
    // …and is called from BOTH the in-place-update and push paths.
    expect(
      chatViewSrc.match(/maybeRefreshWorktreeBinding\(role, event\.tool_name\)/g),
    ).toHaveLength(2)
  })

  it('sidebar refresh button re-syncs the binding before reloading', () => {
    expect(panelSrc).toMatch(/@click="onRefreshClick"/)
    expect(panelSrc).toMatch(/emit\('refresh'\)/)
    expect(shellSrc).toMatch(/@refresh="\(\) => emit\('refresh'\)"/)
    expect(chatViewSrc).toMatch(/@refresh="onChatSidebarRefresh"/)
    expect(chatViewSrc).toMatch(/async function onChatSidebarRefresh\(\)/)
  })

  it('sidebar still receives the worktree-preferring effectiveCwd', () => {
    expect(chatViewSrc).toMatch(/:cwd="effectiveCwd"/)
    expect(chatViewSrc).toMatch(
      /const effectiveCwd = computed\(\(\) => gitWorktreeCwd\.value \|\| sessionCwd\.value\)/,
    )
  })

  it('bottom chip never falls back to a hardcoded main', () => {
    // The stale-'main' bug: `gitStatus.branch || 'main'` showed main
    // while the worktree branch was checked out (detached/loading).
    expect(chatViewSrc).not.toMatch(/\|\| 'main'/)
  })

  it('bottom gitStatus is the single branch source, drilled to the sidebar', () => {
    expect(chatViewSrc).toMatch(/const sidebarBranch = computed/)
    expect(chatViewSrc).toMatch(/:branch="sidebarBranch"/)
    expect(shellSrc).toMatch(/branch\?: string/)
    expect(shellSrc).toMatch(/:branch="branch"/)
    expect(panelSrc).toMatch(/branch\?: string/)
    expect(panelSrc).toMatch(/displayBranch/)
  })

  it('stale fetches cannot overwrite the branch (seq guards, single fetch path)', () => {
    expect(chatViewSrc).toMatch(/gitStatusSeq/)
    expect(panelSrc).toMatch(/loadSeq/)
    // ChatRightSidebar must not fire its own duplicate getGitChanges —
    // the panel's cwd watcher is the only fetch path (expose passthrough
    // for explicit refresh is fine, a watcher is not).
    expect(shellSrc).not.toMatch(/watch\(/)
  })
})

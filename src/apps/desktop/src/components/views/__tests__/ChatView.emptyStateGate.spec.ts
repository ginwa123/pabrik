/** Static contract: the chatview's EMPTY STATE may only render on a server-confirmed empty
 * transcript. */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { readChatViewSource as readChatViewBundle } from '../../../__tests__/helpers/chatViewSource'

const chatViewSrc = readChatViewBundle()
const apiSrc = readFileSync(resolve(__dirname, '../../../api/index.ts'), 'utf8')

describe('ChatView empty state is gated on a server-confirmed empty transcript', () => {
  it('the empty state template requires historyConfirmed', () => {
    // The exact expression, whitespace-tolerantly — prettier wraps this
    // `v-if` across several lines, so a single-line regex would silently stop
    // matching and let a broken file pass.
    expect(chatViewSrc).toMatch(
      /v-if="[\s\S]{0,120}?historyConfirmed\s*&&\s*!isInitializing\s*&&\s*!isLoading\s*&&\s*!error\s*&&\s*messageGroups\.length === 0[\s\S]{0,20}?"/,
    )
  })

  it('historyConfirmed starts false and is only set on a successful load', () => {
    expect(chatViewSrc).toMatch(/const historyConfirmed = ref\(false\)/)
    // Cleared at the start of every load ("not known yet")…
    expect(chatViewSrc).toMatch(/historyConfirmed\.value = false\n/)
    // …and set on the two success exits: cached mount and network commit.
    expect(chatViewSrc.match(/historyConfirmed\.value = true/g)).toHaveLength(2)
  })

  it('the transcript is fetched with the typed variant, not the swallowing one', () => {
    // `getChatHistory` answering `[]` on failure IS the bug; the initial load must use
    // `fetchChatHistoryEffect`, whose error channel keeps "the backend is down" separate from
    // "there are no messages".
    const attemptBody = chatViewSrc.slice(
      chatViewSrc.indexOf('const runHistoryLoadAttempt = async () =>'),
      chatViewSrc.indexOf('const runHistoryLoadAttemptEffect'),
    )
    expect(attemptBody).toMatch(/api\.fetchChatHistoryEffect\(\s*sessionId\.value,/)
    expect(attemptBody).not.toMatch(/api\.getChatHistory\(/)
    // ...with a budget above apiFetch's 15 s default.
    expect(attemptBody).toMatch(/INITIAL_HISTORY_TIMEOUT_MS/)
  })

  it('the initial load is wrapped in the retry schedule, with isLoading held across attempts', () => {
    expect(chatViewSrc).toMatch(/fetchInitialHistoryWithRetry\(runHistoryLoadAttemptEffect/)
    // The attempt body is a separate function so the retry re-runs the whole
    // thing (cache-prime included) rather than a half-applied load.
    expect(chatViewSrc).toMatch(/const runHistoryLoadAttempt = async \(\) =>/)
    // `isLoading` is set true in the wrapper and cleared by `Effect.ensuring` — never between
    // attempts, so the skeleton never flickers out mid-wait. That is the `finally`, expressed on
    // the error channel (AGENTS.md: no `try`/`catch` in the desktop app).
    expect(chatViewSrc).toMatch(
      /Effect\.ensuring\([\s\S]*?Effect\.sync\(\(\) => \{\s*\n\s*isLoading\.value = false/,
    )
  })

  it('a fully-failed load lands in the error state, not the empty state', () => {
    expect(chatViewSrc).toMatch(/error\.value = 'Failed to load messages'/)
    // The handler for the exhausted retry schedule: `Effect.tapError`, not a
    // `catch`, so the failure is read off the error channel.
    expect(chatViewSrc).toMatch(
      /Effect\.tapError\(fetchInitialHistoryWithRetry\([\s\S]*?error\.value = 'Failed to load messages'/,
    )
  })
})

describe('getChatHistory keeps its best-effort contract; fetchChatHistoryEffect does not', () => {
  it('fetchChatHistoryEffect returns an Effect, not a promise that may fake an empty', () => {
    // The whole point of the function is that it does NOT hand back an empty
    // transcript on failure, so it must contain no swallowing catch at all
    // (oxlint's no-useless-catch is what forced this shape; keep it).
    const body = apiSrc.slice(
      apiSrc.indexOf('export function fetchChatHistoryEffect('),
      apiSrc.indexOf('export function getChatHistory('),
    )
    expect(body).toMatch(/Effect\.Effect<ChatHistoryResponse, ChatHistoryError>/)
    expect(body).toMatch(/Effect\.tryPromise\(\{/)
    // No `catch`, and no empty-transcript fallback of its own: the failure
    // leaves on the error channel, which is the entire point.
    expect(body).not.toMatch(/\bcatch \(/)
    expect(body).not.toMatch(/messages: \[\]/)
  })

  it('getChatHistory still swallows — AppLayout cwd fallback + worktree refresh depend on it', () => {
    // Pinned by sseSkills.spec.ts too; reverting this reintroduces a silent
    // failure for the three best-effort metadata callers.
    expect(apiSrc).toMatch(
      /export function getChatHistory\([\s\S]*?fetchChatHistoryEffect\(sessionId, limit, cursor, direction\)[\s\S]*?Effect\.catchAll\(/,
    )
    // The empty shape is a named constant, not an inline literal, so a reader
    // can tell it apart from a real response at a glance.
    expect(apiSrc).toMatch(/const EMPTY_CHAT_HISTORY: ChatHistoryResponse = \{/)
  })
})

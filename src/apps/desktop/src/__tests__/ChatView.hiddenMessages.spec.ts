/** Regression tests for the 2026-08-23 "hidden messages" fix. Background: several classes of
 * legitimately-saved messages were invisible in the chatview: F1. */
import { describe, it, expect } from 'vitest'
import { stripThinkingTags } from '../helpers/stripTags'

const readChatViewSource = async (): Promise<string> => {
  const fs = await import('node:fs/promises')
  const path = await import('node:path')
  const chatviewPath = path.resolve(__dirname, '..', 'components', 'views', 'ChatView.vue')
  return fs.readFile(chatviewPath, 'utf8')
}

describe('F1 — filteredMessages exemptions (source contract)', () => {
  it('keeps image-only messages (image_urls populated)', async () => {
    const source = await readChatViewSource()
    // The exemption must exist INSIDE the filteredMessages filter body.
    expect(source).toMatch(/if \(\(m\.image_urls\?\.length \?\? 0\) > 0\) return true/)
  })

  it('keeps role=tool messages regardless of stripped content', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/if \(m\.role === 'tool'\) return true/)
  })

  it('keeps assistant messages that carry reasoning_content', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(
      /m\.role === 'assistant' && m\.reasoning_content && m\.reasoning_content\.trim\(\) !== ''/,
    )
  })
})

describe('F2 — user group renders ALL messages (source contract)', () => {
  it('template v-fors over group.messages instead of rendering [0] only', async () => {
    const source = await readChatViewSource()
    // The user branch must iterate every message...
    expect(source).toMatch(/v-for="\(userMsg, userMsgIdx\) in group\.messages"/)
    // ...and must NOT render the old [0]-only text interpolation.
    expect(source).not.toMatch(/\{\{ group\.messages\[0\]!\.content \}\}/)
  })

  it('hasBubbleContent checks every user message, not just [0]', async () => {
    const source = await readChatViewSource()
    // The user branch of hasBubbleContent must use .some(...) over all
    // messages (the old code read group.messages[0] directly).
    const userBranch = source.match(/if \(group\.role === 'user'\) \{[\s\S]*?\n  \}/)
    expect(userBranch).not.toBeNull()
    expect(userBranch![0]).toContain('group.messages.some(')
    expect(userBranch![0]).not.toContain('group.messages[0]')
  })
})

describe('F3 — NO optimistic user message push (source contract)', () => {
  // 2026-08-23 auto-collapse fix — the optimistic local push that lived in handleFileInputSubmit
  // was removed.
  it('does NOT push a local optimistic user bubble in handleFileInputSubmit', async () => {
    const source = await readChatViewSource()
    // The optimistic push has been removed; the send-error path now
    // just surfaces a single assistant error bubble.
    expect(source).not.toMatch(/id: `optimistic-user-\$\{Date\.now\(\)\}`/)
    expect(source).not.toMatch(
      /role: 'user',\s*\n\s*content: userMessage,\s*\n\s*timestamp: new Date\(\),\s*\n\s*image_urls: imageUrls\.length > 0 \? imageUrls : undefined/,
    )
  })

  it('does NOT dedupe the SSE echo against a synthetic optimistic id', async () => {
    const source = await readChatViewSource()
    // The full-handler no longer searches for `optimistic-user-*`
    // placeholders to splice out; user echoes arrive fresh.
    expect(source).not.toMatch(/m\.id\.startsWith\('optimistic-user-'\)/)
  })

  it('handleFileInputSubmit only fires api.sendChatMessage + error fallback', async () => {
    const source = await readChatViewSource()
    // The send-error branch now appends a single error assistant bubble
    // instead of rolling back a local placeholder that no longer exists.
    expect(source).toMatch(/await api\.sendChatMessage\(/)
    expect(source).toMatch(
      /Sorry, I encountered an error sending your message\. Please try again\./,
    )
  })
})

describe('B4(frontend) — reasoning_content rendering (source contract)', () => {
  it('maps reasoning_content in the loadChatHistory REST path', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/reasoning_content: msg\.reasoning_content \|\| undefined/)
  })

  it('maps reasoning_content in the SSE full handler', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/reasoning_content: event\.reasoning_content \|\| undefined/)
  })

  it('accepts full events with empty content but renderable fields', async () => {
    const source = await readChatViewSource()
    // The old gate `event.finish_reason && event.content` silently
    // dropped tool-result / image-only / reasoning-only events.
    expect(source).toMatch(/hasRenderableFullPayload/)
    expect(source).not.toMatch(/event\.type === 'full' && event\.finish_reason && event\.content\)/)
  })

  it('renders a collapsible reasoning section in the assistant bubble', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/class="assistant-reasoning"/)
    expect(source).toMatch(/Thought/)
  })

  // task_1790090788150_2: the Thought block must read FIRST, above the
  // assistant's answer — reasoning is the context the reply follows
  // from, not a footnote under it.
  it('renders the Thought block ABOVE the assistant message text', async () => {
    const source = await readChatViewSource()
    const thoughtIdx = source.indexOf('class="assistant-reasoning"')
    const messagesIdx = source.indexOf('class="assistant-messages"')
    expect(thoughtIdx).toBeGreaterThan(-1)
    expect(messagesIdx).toBeGreaterThan(-1)
    expect(thoughtIdx).toBeLessThan(messagesIdx)
  })

  it('accumulates reasoning chunks onto the streaming message', async () => {
    const source = await readChatViewSource()
    // `=\s*` — prettier wraps the assignment after `=`, so the accumulate
    // statement spans two lines (the old one-line regex went red on main).
    expect(source).toMatch(
      /existingMsg\.reasoning_content =\s*\(existingMsg\.reasoning_content \|\| ''\) \+ event\.reasoning_content/,
    )
  })
})

describe('stripThinkingTags — filter interplay (unit)', () => {
  it('returns empty for whitespace-only content (the drop case)', () => {
    expect(stripThinkingTags('   ').trim()).toBe('')
    expect(stripThinkingTags('').trim()).toBe('')
  })

  it('returns empty for <think>-wrapped content when a sibling tag exists', () => {
    // With a <plain> sibling, the think block is stripped and the
    // plain wrapper unwrapped — leaving the inner text.
    expect(stripThinkingTags('<think>secret</think><plain>hello</plain>')).toBe('hello')
  })

  it('keeps lone <think> content intact (rendered as thinking bubble)', () => {
    // Lone <think> is returned unchanged by design — renderResponse
    // detects it via isThinkingTags and renders the collapsed variant.
    expect(stripThinkingTags('<think>reasoning only</think>')).toBe('<think>reasoning only</think>')
  })
})

// -------------------------------------------------------------------------
// Wrapper-tag rendering — <html> and <mermaid>
// -------------------------------------------------------------------------
describe('Rich-block support — ChatView render branch (source contract)', () => {
  it('imports the rich-block helpers from @/helpers', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/import \{[^}]*hasRichBlocks[^}]*\} from '@\/helpers'/)
    expect(source).toMatch(/import \{[^}]*extractRichBlocks[^}]*\} from '@\/helpers'/)
  })

  it('branches the assistant template on hasRichBlocks before the v-html path', async () => {
    const source = await readChatViewSource()
    // The template must check hasRichBlocks(msg.content) and render the
    // iframe/diagram branches INSTEAD of the legacy v-html span for that
    // message.
    expect(source).toMatch(/v-if="msg\.role === 'assistant' && hasRichBlocks\(msg\.content\)"/)
    // The legacy renderResponse call site survives (v-else path).
    expect(source).toMatch(/renderResponse\(\s*\n\s*msg\.content,/)
  })

  it('renders html blocks in a sandboxed iframe (allow-scripts only)', async () => {
    const source = await readChatViewSource()
    // Security contract: sandbox WITHOUT allow-same-origin (null origin
    // = the security boundary; inner scripts can't touch parent DOM).
    expect(source).toMatch(/sandbox="allow-scripts"/)
    expect(source).toMatch(/:srcdoc=/)
    expect(source).not.toMatch(/sandbox="allow-scripts allow-same-origin"/)
  })

  it('splits a message into per-block segments with extractRichBlocks', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/extractRichBlocks\(msg\.content \|\| ''\)/)
  })

  it('renders a mermaid segment through MermaidDiagram, never as HTML', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/import MermaidDiagram from '\.\.\/chat\/MermaidDiagram\.vue'/)
    expect(source).toMatch(
      /v-else-if="seg\.kind === 'mermaid' && seg\.payload"\s*\n\s*:source="seg\.payload"/,
    )
    // The mermaid source is text handed to the diagram component — it must
    // not reach the DOM through the markdown `v-html` branch.
    expect(source).toMatch(/v-if="seg\.kind === 'markdown' && seg\.payload"/)
  })

  it('wraps fragment blocks in a minimal srcdoc shell via buildHtmlSrcdoc', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/const buildHtmlSrcdoc/)
  })

  it('styles the frame with the chat-html-frame class', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/class="chat-html-frame"/)
    expect(source).toMatch(/\.chat-html-frame \{/)
  })

  // 2026-09-13 (task_1789312493325_7 "html render"): PR #309 shipped the iframe with a WHITE
  // background and no height management, so an LLM that answered in HTML mode (the
  // response-formatting prompt offers it) put a bright slab with its own scrollbar inside the dark.
  it('paints the frame with the app theme instead of a hardcoded white', async () => {
    const source = await readChatViewSource()
    // The frame element ...
    expect(source).toMatch(/\.chat-html-frame \{[\s\S]*?background: var\(--semantic-card-bg/)
    expect(source).toMatch(/\.chat-html-frame \{[\s\S]*?color-scheme: dark/)
    // ... and the srcdoc shell it wraps fragments in.
    expect(source).not.toMatch(/background:#fff/)
    expect(source).toMatch(/:root\{color-scheme:dark\}/)
    expect(source).toMatch(/resolveHtmlFramePalette/)
  })

  it('auto-sizes the frame from its own reported content height', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/autoResizeScript\(CHAT_HTML_FRAME_RESIZE_SOURCE\)/)
    expect(source).toMatch(/readAutoResizeHeight\(event, CHAT_HTML_FRAME_RESIZE_SOURCE\)/)
    expect(source).toMatch(/findSenderFrame\(document, event, 'iframe\.chat-html-frame'\)/)
    // The listener must be torn down with the view.
    expect(source).toMatch(/window\.removeEventListener\('message', onHtmlFrameResize\)/)
  })

  // 2026-09-13 follow-up (same task): the model authors this HTML blind — real payload
  // 1789313976387498377 shipped GitHub's light `background:#f6f8fa` inline on every <pre>, which
  // beat the shell stylesheet and left theme ink on a light chip (1.57:1 contrast).
  it('forces the text surfaces so payload-authored light colours cannot win', async () => {
    const source = await readChatViewSource()
    // `!important` is the point: an inline style loses to it.
    expect(source).toMatch(
      /pre,code,th,td\{background:\$\{p\.chip\}!important;color:\$\{p\.fg\}!important\}/,
    )
    expect(source).toMatch(/pre code\{background:transparent!important;padding:0\}/)
    // Chip + inline-code ink come from the app's own markdown tokens.
    expect(source).toMatch(/readCssVar\('--color-bg-p1'/)
    expect(source).toMatch(/readCssVar\('--color-aqua'/)
  })

  // 2026-09-20 no-inner-scrollbar: HTML frames grow to their FULL content
  // height (no 2000px cap) with scrolling="no" + overflow hidden, so the
  // outer chat scroller owns scrolling and no gray inner scrollbar appears.
  it('grows html frames to full height with no inner scrollbar', async () => {
    const source = await readChatViewSource()
    expect(source).toMatch(/growFrameToContent\(reported\)/)
    expect(source).toMatch(/scrolling="no"/)
    expect(source).toMatch(/FRAME_NO_SCROLLBAR_STYLE/)
    expect(source).toMatch(/\.chat-html-frame::-webkit-scrollbar/)
  })
})

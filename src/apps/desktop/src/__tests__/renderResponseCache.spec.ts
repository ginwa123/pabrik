import { describe, expect, it, beforeEach } from 'vitest'
import {
  renderResponse,
  renderStreamingResponse,
  renderMarkdown,
  _resetRenderResponseCache,
} from '../helpers/renderResponse'

const CACHE_CAPACITY = 200

const growing = (prefix: string, chars: number): string => prefix + 'x'.repeat(chars)

describe('rendering one chat message to HTML', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  it('renders an assistant message as markdown', () => {
    expect(renderResponse('# Title\n\nsome **bold** text', 'assistant')).toContain('<h1')
  })

  it('escapes a user message instead of rendering its markdown', () => {
    expect(renderResponse('# not a heading', 'user')).toBe('# not a heading')
  })

  it('renders an empty tool row as its tool pill', () => {
    expect(renderResponse('', 'tool', 'read_file')).toContain('read_file')
  })

  it('renders an empty non-tool row as nothing', () => {
    expect(renderResponse('   ', 'assistant')).toBe('')
  })
})

describe('rendering many distinct messages', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  it('gives every message its own content when the count exceeds the cache capacity', () => {
    const total = CACHE_CAPACITY + 50
    const messages = Array.from({ length: total }, (_, i) => `## message ${i}`)

    const first = messages.map((m) => renderResponse(m, 'assistant'))
    const second = messages.map((m) => renderResponse(m, 'assistant'))

    expect(second).toEqual(first)
    expect(new Set(first).size).toBe(total)
    messages.forEach((m, i) => {
      expect(first[i]).toContain(`message ${i}`)
    })
  })

  it('keeps each message intact across repeated re-renders of the whole set', () => {
    const messages = ['## alpha', '## beta', '## gamma']
    const expected = messages.map((m) => renderResponse(m, 'assistant'))

    for (let round = 0; round < 300; round += 1) {
      messages.forEach((m, i) => {
        expect(renderResponse(m, 'assistant')).toBe(expected[i])
      })
    }
  })
})

describe('a message that is still streaming', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  it('renders the same HTML as a settled message of the same content', () => {
    const content = '## streaming answer\n\ntext'
    expect(renderStreamingResponse(content, 'assistant')).toBe(renderResponse(content, 'assistant'))
  })

  it('follows the content as deltas arrive', () => {
    renderStreamingResponse('first', 'assistant')
    expect(renderStreamingResponse('first and second', 'assistant')).toContain('first and second')
  })

  it('does not disturb the rendered HTML of messages that are already settled', () => {
    const settled = '## settled answer\n\nunchanged'
    const expected = renderResponse(settled, 'assistant')

    for (let chars = 1; chars <= 400; chars += 1) {
      renderStreamingResponse(growing('## live answer\n\n', chars), 'assistant')
    }

    expect(renderResponse(settled, 'assistant')).toBe(expected)
  })
})

describe('rendering markdown without a message envelope', () => {
  beforeEach(() => {
    _resetRenderResponseCache()
  })

  it('renders the same HTML on every call', () => {
    const payload = '## segment\n\nprose'
    expect(renderMarkdown(payload)).toBe(renderMarkdown(payload))
    expect(renderMarkdown(payload)).toContain('<h2')
  })

  it('keeps the message-envelope tags that an assistant message unwraps', () => {
    const payload = '<think>private reasoning</think><markdown>## visible</markdown>'

    const asMessage = renderResponse(payload, 'assistant')
    const asSegment = renderMarkdown(payload)

    expect(asMessage).not.toContain('private reasoning')
    expect(asMessage).not.toContain('<markdown>')
    expect(asSegment).toContain('private reasoning')
    expect(renderMarkdown(payload)).toBe(asSegment)
  })
})

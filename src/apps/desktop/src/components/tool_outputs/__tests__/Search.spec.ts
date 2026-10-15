/**
 * Tests for Search.vue — the chatview toast card for the `search` agent tool.
 *
 * Locks in the operator-visible behaviour that fixes the
 * "unknown pattern not found" rendering bug:
 *  - When the JSON data payload contains `pattern` / `path`,
 *    the header MUST show `"X"` and `in Y` (not the literal "unknown").
 *  - When the payload contains a `warning` (no-match warning),
 *    the warning text MUST appear in the header's right-hand side.
 *  - The default view MUST stay minimal — the operator can click to
 *    expand and see the full Arguments block (handled by the surrounding
 *    ChatView parent, not Search.vue itself).
 *
 * See docs/superpowers/plans/2026-08-06-search-better-error.md.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'
import { defineComponent, h, provide } from 'vue'

import Search from '../Search.vue'
import { OPEN_IN_CODE_EDITOR_KEY, type OpenInCodeEditorFn } from '@/composables/useCodeEditor'

// ──────────────────────────────────────────────────────────────────────── Test fixtures — match
// the JSON data shape in docs/superpowers/plans/2026-09-18-agent-tool-output-json-schema.md §2.3
// ────────────────────────────────────────────────────────────────────────
interface MatchFixture {
  line: number
  text: string
}

/**
 * No-match payload: `files: []` + a `warning` body.
 */
const noMatchData = (pattern = 'needle_NOT_FOUND', path = '/tmp/repo/src') => ({
  pattern,
  path,
  returned: 0,
  total: 0,
  truncated: false,
  truncated_hint: null,
  files: [],
  warning: `no matches for pattern "${pattern}" in path "${path}"`,
})

/**
 * One-match payload with a single file block.
 */
const oneMatchData = (pattern = 'TODO', path = '/tmp/repo/src') => ({
  pattern,
  path,
  returned: 1,
  total: 1,
  truncated: false,
  truncated_hint: null,
  files: [
    {
      path: '/tmp/repo/src/foo.ts',
      total: 100,
      count: 1,
      matches: [{ line: 42, text: '    // TODO: fix this' }],
    },
  ],
  warning: null,
})

const makeWrapper = (
  props: { content: unknown; cwd?: string; expanded?: boolean; parameters?: string },
  provideOpenInEditor?: OpenInCodeEditorFn,
) => {
  if (provideOpenInEditor) {
    return mount(
      defineComponent({
        setup() {
          provide(OPEN_IN_CODE_EDITOR_KEY, provideOpenInEditor)
          return () => h(Search, props as never)
        },
      }),
    )
  }
  return mount(Search, { props: props as never })
}

afterEach(() => {
  document.body.innerHTML = ''
})

// ────────────────────────────────────────────────────────────────────────
// Header rendering — the operator's first-glance view of what was searched
// ────────────────────────────────────────────────────────────────────────
describe('Search.vue — header rendering (operator-visible pattern + path)', () => {
  it('shows the actual pattern from the payload, not "unknown" (regression: bug 2026-08-06)', () => {
    const wrapper = makeWrapper({ content: noMatchData('needle_NOT_FOUND', '/tmp/x') })

    // The pattern text appears inside quotes in the header. Specifically
    // NOT the literal "unknown" that the pre-fix payload (no pattern key)
    // produced.
    const html = wrapper.html()
    expect(html).toContain('needle_NOT_FOUND')
    // The header should NOT fall back to "unknown" because the payload
    // carries pattern="needle_NOT_FOUND".
    expect(html).not.toContain('"unknown"')
  })

  it('shows the actual path from the payload, not "unknown"', () => {
    const wrapper = makeWrapper({ content: noMatchData('foo', '/repo/path/src') })

    const html = wrapper.html()
    expect(html).toContain('in /repo/path/src')
    // The "in unknown" fallback would render if the pattern/path lookup
    // returned null. With the new backend payload it MUST return the
    // real path.
    expect(html).not.toContain('in unknown')
  })

  it('renders both the pattern and the path together in the header', () => {
    const wrapper = makeWrapper({
      content: noMatchData('readFileAlloc|readFile', '/home/ginwa/repo/src/modules'),
    })

    const html = wrapper.html()
    expect(html).toContain('readFileAlloc|readFile')
    expect(html).toContain('/home/ginwa/repo/src/modules')
  })

  it('renders the warning text from the payload', () => {
    const wrapper = makeWrapper({ content: noMatchData() })

    // The header's right-hand side shows the warning body, styled orange. Locks in that the
    // no-match warning surfaces the actionable message ("no matches for pattern...") so the
    // operator can copy/paste it into a chat.
    const html = wrapper.html()
    expect(html).toContain('no matches for pattern')
    expect(html).toContain('needle_NOT_FOUND')
    expect(html).toContain('/tmp/repo/src')
  })

  it('falls back to "unknown" only when the payload truly has no pattern', () => {
    // Payload without pattern/path keys. We keep the "unknown" fallback for back-compat with stale
    // rows. The fix's job is to ensure NEW results carry the keys; this test confirms we haven't
    // broken the fallback.
    const wrapper = makeWrapper({
      content: { warning: 'pattern not found', files: [] },
    })

    expect(wrapper.html()).toContain('unknown')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Match-found payload — must still work after the no-match fix
// ────────────────────────────────────────────────────────────────────────
describe('Search.vue — match-found payload (regression guard)', () => {
  it('renders the pattern + path on match results', () => {
    const wrapper = makeWrapper({
      content: oneMatchData('TODO', '/repo/src'),
    })

    expect(wrapper.html()).toContain('TODO')
    expect(wrapper.html()).toContain('/repo/src')
  })

  it('does NOT render the "unknown" fallback when payload has pattern/path', () => {
    const wrapper = makeWrapper({
      content: oneMatchData('TODO', '/repo/src'),
    })

    const html = wrapper.html()
    expect(html).not.toContain('"unknown"')
    expect(html).not.toContain('in unknown')
  })
})

// ──────────────────────────────────────────────────────────────────────── Empty/no-match results —
// Arguments must still be reachable.
// Bug: the expanded body was `v-if="isExpanded && fileResults.length > 0"` and toggle() refused to
// expand on a warning/empty payload, so a no-match search (warning payload) could never show its
// Arguments block. ────────────────────────────────────────────────────────────────────────
describe('Search.vue — warning payload still shows Arguments (empty/no-match)', () => {
  const warningContent = {
    pattern: 'foo',
    path: '/tmp',
    returned: 0,
    total: 0,
    truncated: false,
    truncated_hint: null,
    files: [],
    warning: 'no matches for pattern',
  }
  const params = JSON.stringify({ pattern: 'foo', path: '/tmp' })

  it('shows Arguments when expanded via prop', () => {
    const wrapper = makeWrapper({ content: warningContent, parameters: params, expanded: true })

    const html = wrapper.html()
    expect(html).toContain('Arguments')
    expect(html).toContain('foo')
  })

  it('shows Arguments after header click', async () => {
    const wrapper = makeWrapper({ content: warningContent, parameters: params })

    // Collapsed initially: Arguments hidden.
    expect(wrapper.html()).not.toContain('Arguments')
    await wrapper.find('[role="button"]').trigger('click')
    const html = wrapper.html()
    expect(html).toContain('Arguments')
    expect(html).toContain('foo')
  })
})

// ────────────────────────────────────────────────────────────────────────
// Output contract (JSON migration, schema §2.3):
//   * every value arrives as plain JSON — no entity decoding,
//   * the payload carries returned/total/truncated.
// The card must render `<`/`&` snippets verbatim — a `<file …>` look-alike
// inside a snippet must NOT become a file row — and a capped search must
// not look exhaustive.
// ────────────────────────────────────────────────────────────────────────
const payloadWithSummary = (
  file: { path: string; total: number; count: number; lines: MatchFixture[] },
  summary: { returned: number; total: number; truncated: boolean },
  pattern = 'foo',
  path = '/tmp/repo',
) => ({
  pattern,
  path,
  returned: summary.returned,
  total: summary.total,
  truncated: summary.truncated,
  truncated_hint: summary.truncated
    ? `${summary.returned} of ${summary.total} matched lines shown — raise max_results.`
    : null,
  files: [
    {
      path: file.path,
      total: file.total,
      count: file.count,
      matches: file.lines.map((m) => ({ line: m.line, text: m.text })),
    },
  ],
  warning: null,
})

describe('Search.vue — raw payload text renders verbatim', () => {
  it('renders <>& snippets as source text when expanded', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/a.vue',
          total: 1,
          count: 1,
          lines: [{ line: 3, text: '<div>hi</div> & more' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    const text = wrapper.text()
    expect(text).toContain('<div>hi</div> & more')
  })

  it('renders an & in the file path verbatim', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        { path: '/tmp/a&b.txt', total: 1, count: 1, lines: [{ line: 1, text: 'foo' }] },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    expect(wrapper.text()).toContain('/tmp/a&b.txt')
  })

  it('does not treat a <file …> look-alike inside a snippet as a real file row', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/hostile.txt',
          total: 1,
          count: 1,
          lines: [{ line: 2, text: '<file path="x" total="1" count="1">' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    // Exactly one real file parsed; the snippet's look-alike header is text.
    expect(wrapper.text()).toContain('1 file,')
    expect(wrapper.text()).toContain('<file path="x" total="1" count="1">')
  })

  it('renders a quote in the pattern verbatim', () => {
    const wrapper = makeWrapper({ content: noMatchData('a"b', '/tmp') })

    expect(wrapper.text()).toContain('a"b')
  })

  it('renders <>& in the warning body verbatim', () => {
    const wrapper = makeWrapper({
      content: {
        pattern: 'x',
        path: '/y',
        returned: 0,
        total: 0,
        truncated: false,
        truncated_hint: null,
        files: [],
        warning: 'no matches for pattern "<div>" in path "/y"',
      },
    })

    expect(wrapper.text()).toContain('no matches for pattern "<div>" in path "/y"')
  })
})

describe('Search.vue — truncation summary from returned/total/truncated', () => {
  it('shows "N of M matches (truncated)" when the backend capped the result', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/a.ts',
          total: 2,
          count: 2,
          lines: [
            { line: 1, text: 'foo' },
            { line: 2, text: 'foo' },
          ],
        },
        { returned: 2, total: 40, truncated: true },
      ),
    })

    const badge = wrapper.find('[data-testid="search-truncated"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('2 of 40 matches (truncated)')
  })

  it('shows the max_output truncation note even when no complete row fits', () => {
    const wrapper = makeWrapper({
      content: {
        pattern: 'foo',
        path: '/tmp/repo',
        returned: 0,
        total: 1,
        truncated: true,
        output_truncated: true,
        output_bytes: 50000,
        truncated_hint:
          'Search output exceeded the requested max_output (observed 50000 bytes); only complete records in the retained prefix are shown. Results were truncated.',
        grouped: true,
        files: [],
        warning: null,
      },
    })

    const note = wrapper.find('[data-testid="search-truncation-hint"]')
    expect(note.exists()).toBe(true)
    expect(note.text()).toContain('max_output')
    expect(note.text()).toContain('truncated')
    expect(wrapper.find('[data-testid="search-expandable"]').exists()).toBe(true)
  })

  it('keeps the plain wording when truncated=false', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        { path: '/tmp/repo/a.ts', total: 1, count: 1, lines: [{ line: 1, text: 'foo' }] },
        { returned: 1, total: 1, truncated: false },
      ),
    })

    expect(wrapper.text()).toContain('1 file, 1 match')
    expect(wrapper.find('[data-testid="search-truncated"]').exists()).toBe(false)
  })

  it('keeps the plain wording for legacy payloads without summary counts', () => {
    const wrapper = makeWrapper({
      content: {
        pattern: 'TODO',
        path: '/repo/src',
        files: [
          {
            path: '/repo/src/foo.ts',
            total: 100,
            count: 1,
            matches: [{ line: 42, text: '// TODO: fix this' }],
          },
        ],
        warning: null,
      },
    })

    expect(wrapper.text()).toContain('1 file, 1 match')
    expect(wrapper.find('[data-testid="search-truncated"]').exists()).toBe(false)
  })

  it('accepts the data payload as a JSON string', () => {
    const wrapper = makeWrapper({
      content: JSON.stringify(oneMatchData('TODO', '/repo/src')),
    })

    expect(wrapper.html()).toContain('TODO')
    expect(wrapper.text()).toContain('1 file, 1 match')
  })
})

describe('Search.vue — code coloring (parity with ReadFile/DiffView)', () => {
  it('highlights keywords/strings/comments for a known language (ts)', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/main.ts',
          total: 1,
          count: 1,
          lines: [{ line: 1, text: 'const name = "ada"; // greeting' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    // Verbatim text preserved through token spans.
    expect(wrapper.text()).toContain('const name = "ada"; // greeting')
    const html = wrapper.html()
    expect(html).toContain('tok-keyword')
    expect(html).toContain('tok-string')
    expect(html).toContain('tok-comment')
  })

  it('renders plaintext without token colors for .txt', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/notes.txt',
          total: 1,
          count: 1,
          lines: [{ line: 1, text: 'const name = "ada"; // greeting' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    expect(wrapper.text()).toContain('const name = "ada"; // greeting')
    const html = wrapper.html()
    expect(html).not.toContain('tok-keyword')
    expect(html).not.toContain('tok-string')
    expect(html).toContain('tok-plain')
  })

  it('falls back to plaintext for unknown extensions', () => {
    const wrapper = makeWrapper({
      content: payloadWithSummary(
        {
          path: '/tmp/repo/file.unknownext',
          total: 1,
          count: 1,
          lines: [{ line: 1, text: 'const x = 42' }],
        },
        { returned: 1, total: 1, truncated: false },
      ),
      expanded: true,
    })

    expect(wrapper.text()).toContain('const x = 42')
    expect(wrapper.html()).not.toContain('tok-keyword')
  })

  it('derives language per file so mixed results highlight independently', () => {
    const wrapper = makeWrapper({
      content: {
        pattern: 'x',
        path: '/tmp/repo',
        returned: 2,
        total: 2,
        truncated: false,
        truncated_hint: null,
        files: [
          {
            path: '/tmp/repo/a.ts',
            total: 1,
            count: 1,
            matches: [{ line: 1, text: 'const x = 42' }],
          },
          {
            path: '/tmp/repo/notes.txt',
            total: 1,
            count: 1,
            matches: [{ line: 1, text: 'const x = 42' }],
          },
        ],
        warning: null,
      },
      expanded: true,
    })

    const html = wrapper.html()
    // TS file contributes keyword/number tokens; txt file stays plain.
    expect(html).toContain('tok-keyword')
    expect(html).toContain('tok-number')
    expect(html).toContain('tok-plain')
  })
})

/** Tests for WebSearch.vue — the tool-output card for the `web_search` agent tool. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import WebSearch from '../WebSearch.vue'
import { parseWebSearch, parseWebSearchErrorText } from '../_shared/toolOutputParser'

// ─── Envelopes, shaped like the ones the backend emits ─────────────────────
const successEnvelope = (provider: string, response: unknown, status = 200) => ({
  provider,
  status,
  response,
})

const failureEnvelope = (error: string) => ({
  tool: 'web_search',
  parameters: { provider: 'tinyfish', curl: 'curl https://api/search.tinyfish.ai?q=x' },
  success: false,
  data: null,
  error,
  v: 1,
})

const tinyfish = {
  results: [
    {
      position: 1,
      site_name: 'example.com',
      title: 'World Cup final',
      url: 'https://example.com/final',
      snippet: 'The final was played on Sunday.',
    },
    {
      position: 2,
      site_name: 'other.test',
      title: 'Match report',
      url: 'https://other.test/report',
      snippet: 'A second result.',
    },
  ],
}

// ─── Tests ─────────────────────────────────────────────────────────────────
describe('WebSearch', () => {
  it('renders the card', () => {
    const wrapper = mount(WebSearch, {
      props: { content: successEnvelope('tinyfish', tinyfish), expanded: true },
    })
    expect(wrapper.find('[data-testid="web-search-card"]').exists()).toBe(true)
  })

  // ─── matrix row 69: the `results` convention ────────────────────────────
  it('69: renders one row per result of a top-level `results` array', () => {
    const wrapper = mount(WebSearch, {
      props: { content: successEnvelope('tinyfish', tinyfish), expanded: true },
    })

    expect(wrapper.findAll('[data-testid^="web-search-row-"]')).toHaveLength(2)
    expect(wrapper.text()).toContain('World Cup final')
    expect(wrapper.text()).toContain('https://example.com/final')
    expect(wrapper.text()).toContain('The final was played on Sunday.')
    // The list IS the rendering — the raw JSON must not be shown as well.
    expect(wrapper.find('[data-testid="web-search-json"]').exists()).toBe(false)
  })

  it('69: shows whichever of snippet / description / content the provider sent', () => {
    // Brave calls it `description`, a self-hosted SearxNG calls it `content`.
    const brave = { results: [{ title: 'B', url: 'https://b.test', description: 'brave body' }] }
    const searxng = { results: [{ title: 'S', url: 'https://s.test', content: 'searx body' }] }

    const braveWrapper = mount(WebSearch, {
      props: { content: successEnvelope('brave', brave), expanded: true },
    })
    expect(braveWrapper.find('[data-testid="web-search-result-body"]').text()).toBe('brave body')

    const searxWrapper = mount(WebSearch, {
      props: { content: successEnvelope('searxng', searxng), expanded: true },
    })
    expect(searxWrapper.find('[data-testid="web-search-result-body"]').text()).toBe('searx body')
  })

  it('69: an empty `results` array says so rather than rendering as JSON', () => {
    const wrapper = mount(WebSearch, {
      props: { content: successEnvelope('tinyfish', { results: [] }), expanded: true },
    })

    expect(wrapper.find('[data-testid="web-search-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="web-search-json"]').exists()).toBe(false)
  })

  it('69: the header counts the results and the badge names the provider', () => {
    const wrapper = mount(WebSearch, {
      props: { content: successEnvelope('tinyfish', tinyfish), expanded: true },
    })

    expect(wrapper.text()).toContain('2 results')
    expect(wrapper.find('[data-testid="web-search-provider"]').text()).toContain('tinyfish')
    expect(wrapper.find('[data-testid="tool-card-primary"]').text()).toBe('tinyfish')
  })

  // ─── matrix row 70: the fallback, and never a throw ─────────────────────
  it.each([
    ['Brave nests the same array under `web`', { web: { results: [{ title: 'B' }] } }],
    ['Serper calls it `organic`', { organic: [{ title: 'O', link: 'https://o.test' }] }],
    ['a self-hosted SearxNG answers a bare array', [{ title: 'S', url: 'https://s.test' }]],
    ['an entirely alien shape', { quantum: { flux: [1, 2, 3] } }],
    ['a bare string', 'not an object at all'],
    ['a bare number', 42],
  ])('70: %s falls back to formatted JSON without throwing', (_label, response) => {
    let wrapper
    expect(() => {
      wrapper = mount(WebSearch, {
        props: { content: successEnvelope('tinyfish', response), expanded: true },
      })
    }).not.toThrow()

    const json = wrapper!.find('[data-testid="web-search-json"]')
    expect(json.exists()).toBe(true)
    expect(wrapper!.findAll('[data-testid^="web-search-row-"]')).toHaveLength(0)
    // The payload is shown verbatim — not summarised, not swallowed.
    expect(json.text()).toBe(JSON.stringify(response, null, 2))
  })

  it('70: a payload that cannot be serialised says so, and does not read as "no results"', () => {
    // An unfamiliar shape is normal (D13); one that JSON.stringify refuses is
    // still not an error state, and rendering it as an empty block would be
    // indistinguishable from "the search found nothing".
    const cyclic: Record<string, unknown> = { name: 'loop' }
    cyclic.self = cyclic

    let wrapper
    expect(() => {
      wrapper = mount(WebSearch, {
        props: { content: successEnvelope('tinyfish', cyclic), expanded: true },
      })
    }).not.toThrow()

    expect(wrapper!.text()).toContain('could not be serialised')
    expect(wrapper!.find('[data-testid="web-search-empty"]').exists()).toBe(false)
  })

  it('70: a null / missing response body renders the card, not an exception', () => {
    for (const content of [null, undefined, '', 'not json at all', {}, []]) {
      const wrapper = mount(WebSearch, { props: { content, expanded: true } })
      expect(wrapper.find('[data-testid="web-search-card"]').exists()).toBe(true)
    }
  })

  // ─── matrix row 71: the provider badge ──────────────────────────────────
  it('71: the provider badge comes from the envelope', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: successEnvelope('serper', { organic: [] }),
        parameters: '{"provider":"tinyfish","curl":"curl https://x"}',
        expanded: true,
      },
    })

    // The envelope's word wins over the argument: the card reports who
    // actually answered. (The Arguments block below still shows the call the
    // model made — that is the tool-call arguments, not the badge.)
    expect(wrapper.find('[data-testid="web-search-provider"]').text()).toContain('serper')
    expect(wrapper.find('[data-testid="tool-card-primary"]').text()).toBe('serper')
  })

  it('71: falls back to the argument when the envelope names no provider', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: successEnvelope('', tinyfish),
        parameters: '{"provider":"tinyfish","curl":"curl https://x"}',
        expanded: true,
      },
    })

    expect(wrapper.find('[data-testid="web-search-provider"]').text()).toContain('tinyfish')
  })

  it('71: a malformed `parameters` prop leaves the badge on the envelope', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: successEnvelope('brave', tinyfish),
        parameters: 'not json {',
        expanded: true,
      },
    })

    expect(wrapper.find('[data-testid="web-search-provider"]').text()).toContain('brave')
  })

  it('only makes an http(s) url clickable — the payload is untrusted passthrough', () => {
    // The backend pins the host it REQUESTS and scrubs the key, but it never
    // inspects what came back: a `url` here is whatever the provider wrote,
    // and a clickable `javascript:` href runs in this app's origin.
    const hostile = {
      results: [
        { title: 'fine', url: 'https://ok.test/a', snippet: 's' },
        { title: 'script', url: 'javascript:alert(1)', snippet: 's' },
        { title: 'data', url: 'data:text/html,<h1>x', snippet: 's' },
      ],
    }
    const wrapper = mount(WebSearch, {
      props: { content: successEnvelope('tinyfish', hostile), expanded: true },
    })

    const links = wrapper
      .findAll('[data-testid="web-search-result-link"]')
      .map((l) => l.attributes('href'))
    expect(links).toEqual(['https://ok.test/a'])
    // The other two are shown, as text.
    expect(wrapper.text()).toContain('javascript:alert(1)')
    expect(wrapper.text()).toContain('data:text/html,<h1>x')
    expect(wrapper.html()).not.toContain('href="javascript:')
  })

  // ─── failures ───────────────────────────────────────────────────────────
  it('renders the reason flag and the message of a failure envelope', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: failureEnvelope(
          JSON.stringify({
            error: "Search provider 'tinyfish' quota exhausted (HTTP 429).",
            provider: 'tinyfish',
            exhausted: true,
            other_providers: [{ name: 'brave', url: 'https://api.search.brave.com' }],
          }),
        ),
        expanded: true,
      },
    })

    expect(wrapper.findAll('[data-testid="web-search-flag"]').map((f) => f.text())).toEqual([
      'exhausted',
    ])
    expect(wrapper.find('[data-testid="web-search-error"]').text()).toContain('quota exhausted')
    expect(wrapper.text()).toContain('brave')
    expect(wrapper.text()).toContain('✗')
  })

  it('names the pinned and requested hosts of a host_mismatch', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: failureEnvelope(
          JSON.stringify({
            error:
              "web_search refused: curl host 'attacker.example.com' does not match the pinned host.",
            host_mismatch: true,
            pinned_host: 'api.search.tinyfish.ai',
            requested_host: 'attacker.example.com',
          }),
        ),
        expanded: true,
      },
    })

    const mismatch = wrapper.find('[data-testid="web-search-host-mismatch"]')
    expect(mismatch.exists()).toBe(true)
    expect(mismatch.text()).toContain('attacker.example.com')
    expect(mismatch.text()).toContain('api.search.tinyfish.ai')
  })

  it('renders a plain-text failure with no reason flag of its own', () => {
    const wrapper = mount(WebSearch, {
      props: {
        content: failureEnvelope('The search request could not be sent (DNS, TLS or timeout).'),
        expanded: true,
      },
    })

    expect(wrapper.find('[data-testid="web-search-error"]').text()).toContain('DNS, TLS or timeout')
    // No flag was carried, so none is invented.
    expect(wrapper.find('[data-testid="web-search-flags"]').exists()).toBe(false)
    expect(wrapper.text()).toContain('✗')
  })

  // ─── parser ─────────────────────────────────────────────────────────────
  it('parseWebSearch reads the provider, status and untyped response', () => {
    const parsed = parseWebSearch(successEnvelope('tinyfish', tinyfish))

    expect(parsed.provider).toBe('tinyfish')
    expect(parsed.status).toBe(200)
    expect(parsed.success).toBe(true)
    expect(parsed.response).toEqual(tinyfish)
    expect(parsed.error).toBeNull()
  })

  it('parseWebSearch reports the failure flags off an inner envelope', () => {
    const parsed = parseWebSearch({
      error: 'Unknown search provider',
      unknown_provider: true,
      available: [{ name: 'brave', url: 'https://api.search.brave.com' }],
    })

    expect(parsed.success).toBe(false)
    expect(parsed.error?.flags).toEqual(['unknown_provider'])
    expect(parsed.error?.available).toEqual([
      { name: 'brave', url: 'https://api.search.brave.com' },
    ])
  })

  it("parseWebSearch accepts the plan's bare-name `available` list too", () => {
    const parsed = parseWebSearch({
      error: 'Unknown search provider',
      unknown_provider: true,
      available: ['tinyfish', 'brave'],
    })

    expect(parsed.error?.available).toEqual([
      { name: 'tinyfish', url: '' },
      { name: 'brave', url: '' },
    ])
  })

  it('parseWebSearchErrorText reads flags out of an error that IS the envelope', () => {
    const parsed = parseWebSearchErrorText(
      JSON.stringify({ error: 'No search providers are configured.', configured: false }),
    )

    expect(parsed.flags).toEqual(['configured'])
    expect(parsed.configured).toBe(true)
    expect(parsed.message).toBe('No search providers are configured.')
  })

  it('parseWebSearchErrorText reports a plain sentence with no flags', () => {
    const parsed = parseWebSearchErrorText('web_search needs both `provider` and `curl`.')

    expect(parsed.flags).toEqual([])
    expect(parsed.message).toBe('web_search needs both `provider` and `curl`.')
  })
})

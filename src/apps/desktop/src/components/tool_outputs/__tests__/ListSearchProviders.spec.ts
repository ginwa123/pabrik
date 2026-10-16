/** Tests for ListSearchProviders.vue — the tool-output card for the `list_web_search_providers`
 * agent tool. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ListSearchProviders from '../ListSearchProviders.vue'
import { parseListWebSearchProviders } from '../_shared/toolOutputParser'

const listing = {
  providers: [
    {
      name: 'tinyfish',
      url: 'https://api.search.tinyfish.ai',
      description: 'TinyFish web search',
      curl: "curl 'https://api.search.tinyfish.ai/search?q=world+cup&key={key}'",
    },
    {
      name: 'brave',
      url: 'https://api.search.brave.com',
      description: '',
      curl: "curl -H 'X-Subscription-Token: {key}' 'https://api.search.brave.com/res/v1/web/search?q=x'",
    },
  ],
}

describe('ListSearchProviders', () => {
  it('renders one block per provider with name, url, description and curl', () => {
    const wrapper = mount(ListSearchProviders, { props: { content: listing, expanded: true } })

    expect(wrapper.find('[data-testid="list-search-providers-card"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="search-provider-tinyfish"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="search-provider-brave"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('https://api.search.tinyfish.ai')
    expect(wrapper.text()).toContain('TinyFish web search')
    expect(wrapper.text()).toContain('2 providers')
  })

  it('shows the curl template with its literal {key} placeholder', () => {
    const wrapper = mount(ListSearchProviders, { props: { content: listing, expanded: true } })

    const curls = wrapper.findAll('[data-testid="search-provider-curl"]').map((c) => c.text())
    expect(curls).toHaveLength(2)
    expect(curls[0]).toContain('key={key}')
    expect(curls[1]).toContain('X-Subscription-Token: {key}')
    // The caption names what the placeholder is for, so a user reading the
    // card does not think a field is missing.
    expect(wrapper.text()).toContain('put the key where {key} is')
  })

  it('says so when nothing is configured, instead of rendering an empty card', () => {
    const wrapper = mount(ListSearchProviders, {
      props: { content: { providers: [] }, expanded: true },
    })

    expect(wrapper.find('[data-testid="list-search-providers-empty"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No search providers are configured')
    expect(wrapper.text()).toContain('none configured')
  })

  it('renders a failure envelope with its message and a red card', () => {
    const wrapper = mount(ListSearchProviders, {
      props: {
        content: {
          tool: 'list_web_search_providers',
          parameters: {},
          success: false,
          data: null,
          error: 'list_web_search_providers failed: OutOfMemory',
          v: 1,
        },
        expanded: true,
      },
    })

    expect(wrapper.find('[data-testid="list-search-providers-error"]').text()).toContain(
      'OutOfMemory',
    )
    expect(wrapper.text()).toContain('✗')
  })

  it('renders without throwing on junk input', () => {
    for (const content of [null, undefined, '', 'not json', { providers: 'nope' }, []]) {
      const wrapper = mount(ListSearchProviders, { props: { content, expanded: true } })
      expect(wrapper.find('[data-testid="list-search-providers-card"]').exists()).toBe(true)
    }
  })

  it('skips a row with no name — there is nothing to key a settings edit on', () => {
    const wrapper = mount(ListSearchProviders, {
      props: {
        content: { providers: [{ url: 'https://x.test', curl: 'curl x' }] },
        expanded: true,
      },
    })

    expect(wrapper.find('[data-testid="list-search-providers-empty"]').exists()).toBe(true)
  })

  it('parseListWebSearchProviders reads the four fields per provider', () => {
    const parsed = parseListWebSearchProviders(listing)

    expect(parsed.providers).toHaveLength(2)
    expect(parsed.providers).toEqual([
      {
        name: 'tinyfish',
        url: 'https://api.search.tinyfish.ai',
        description: 'TinyFish web search',
        curl: "curl 'https://api.search.tinyfish.ai/search?q=world+cup&key={key}'",
      },
      {
        name: 'brave',
        url: 'https://api.search.brave.com',
        description: '',
        curl: "curl -H 'X-Subscription-Token: {key}' 'https://api.search.brave.com/res/v1/web/search?q=x'",
      },
    ])
  })

  it('parseListWebSearchProviders unwraps a full envelope', () => {
    const parsed = parseListWebSearchProviders({
      tool: 'list_web_search_providers',
      parameters: {},
      success: true,
      data: listing,
      error: null,
      v: 1,
    })

    expect(parsed.providers.map((p) => p.name)).toEqual(['tinyfish', 'brave'])
  })

  it('parseListWebSearchProviders returns an empty list, never a throw', () => {
    expect(parseListWebSearchProviders(null).providers).toEqual([])
    expect(parseListWebSearchProviders({ providers: { nope: true } }).providers).toEqual([])
  })
})

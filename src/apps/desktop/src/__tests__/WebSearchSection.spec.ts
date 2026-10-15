import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import type { PabrikWebSearchProvider } from '../api'
import WebSearchSection from '../components/pabrik/WebSearchSection.vue'
import {
  parseWebSearchProviders,
  serializeWebSearchProviders,
  validateWebSearchRows,
  webSearchRowErrorsFromMessage,
  type WebSearchProviderRow,
} from '../components/pabrik/webSearchProviders'

/**  * `key` may arrive from the API as a MASK rather than as the secret. `MASKED` stands in for the
 * shape of such a value (leading chars, dots, trailing chars) — the point is that the frontend
 * cannot tell it apart from a real credential, and therefore must never rewrite it. */
const MASKED = 'sk••••••7f2'

const TINYFISH: PabrikWebSearchProvider = {
  url: 'https://api.search.tinyfish.ai',
  key: MASKED,
  curl: 'https://api.search.tinyfish.ai?query=PLACEHOLDER -H "X-API-Key: {key}"',
  description: 'Best for news. Free tier 1000/day.',
}

const SELFHOSTED: PabrikWebSearchProvider = {
  url: 'https://search.internal.example',
  curl: 'https://search.internal.example/search?q=PLACEHOLDER',
}

function rows(raw: Record<string, PabrikWebSearchProvider>): WebSearchProviderRow[] {
  return parseWebSearchProviders(raw)
}

/** Re-read the row list out of the component's latest emit. */
function lastRows(wrapper: ReturnType<typeof mount>): WebSearchProviderRow[] {
  const events = wrapper.emitted('update:modelValue')
  if (!events || events.length === 0) throw new Error('the section never emitted update:modelValue')
  return events[events.length - 1]![0] as WebSearchProviderRow[]
}

function rowByName(list: WebSearchProviderRow[], name: string): WebSearchProviderRow {
  const found = list.find((r) => r.name === name)
  if (!found) throw new Error(`expected a row named ${name}`)
  return found
}

/** The live value of a mounted input/textarea. */
function fieldValue(wrapper: ReturnType<typeof mount>, rowId: string, testid: string): string {
  const el = wrapper.find(`[data-row-id="${rowId}"] [data-testid="${testid}"]`).element
  return (el as HTMLInputElement).value
}

function savedProvider(
  saved: Record<string, PabrikWebSearchProvider> | undefined,
  name: string,
): PabrikWebSearchProvider {
  const entry = saved?.[name]
  if (!entry) throw new Error(`expected a saved provider named ${name}`)
  return entry
}

describe('WebSearchSection', () => {
  it('shows the section explainer', () => {
    const wrapper = mount(WebSearchSection, { props: { modelValue: [] } })
    expect(wrapper.text()).toContain('Web search providers the agent can call')
  })

  it('shows the empty state when no providers exist', () => {
    const wrapper = mount(WebSearchSection, { props: { modelValue: [] } })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
  })

  it('emits add when + Add provider is clicked', async () => {
    const wrapper = mount(WebSearchSection, { props: { modelValue: [] } })
    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.emitted('add')).toBeTruthy()
  })

  it('renders one row per provider with every field', () => {
    const wrapper = mount(WebSearchSection, {
      props: { modelValue: rows({ tinyfish: TINYFISH, selfhosted: SELFHOSTED }) },
    })
    expect(wrapper.findAll('[data-testid^="web-search-row-"]')).toHaveLength(2)

    const row = wrapper.find('[data-row-id="tinyfish"]')
    expect(fieldValue(wrapper, 'tinyfish', 'name-input')).toBe('tinyfish')
    expect(fieldValue(wrapper, 'tinyfish', 'url-input')).toBe(TINYFISH.url)
    // The key is a password field — a secret must not be readable off
    // the screen — but it must be IN the field, or a save would blank it.
    expect(row.find('[data-testid="key-input"]').attributes('type')).toBe('password')
    expect(fieldValue(wrapper, 'tinyfish', 'key-input')).toBe(MASKED)
    expect(fieldValue(wrapper, 'tinyfish', 'curl-textarea')).toBe(TINYFISH.curl)
    expect(fieldValue(wrapper, 'tinyfish', 'description-input')).toBe(TINYFISH.description)
    expect(row.find('[data-testid="toggle-btn"]').attributes('aria-pressed')).toBe('true')
  })

  // ─── The regressions this section exists to prevent ──────────────────────

  it('submitting the MASKED key does not blank the stored key', async () => {
    // The user opens Settings and hits Save without touching the key. The field still holds the
    // backend's mask, and that mask is what goes back — never `""`, which would destroy the stored
    // credential while looking exactly like "the user cleared the field".
    const parsed = rows({ tinyfish: TINYFISH })
    const wrapper = mount(WebSearchSection, { props: { modelValue: parsed } })
    expect(fieldValue(wrapper, 'tinyfish', 'key-input')).toBe(MASKED)

    // A save is a serialize of the rows the component currently holds.
    const saved = serializeWebSearchProviders(parsed)
    expect(savedProvider(saved, 'tinyfish').key).toBe(MASKED)
    expect(savedProvider(saved, 'tinyfish').key).not.toBe('')

    // Editing an unrelated field must not disturb the key either.
    await wrapper
      .find('[data-row-id="tinyfish"] [data-testid="description-input"]')
      .setValue('now with more news')
    const savedAfterEdit = serializeWebSearchProviders(lastRows(wrapper))
    expect(savedProvider(savedAfterEdit, 'tinyfish').key).toBe(MASKED)
  })

  it('an EMPTY key is OMITTED from the payload, not sent as an empty string', () => {
    // A self-hosted provider has no credential. `{"key": ""}` is a DIFFERENT thing to the backend
    // than an absent key — an empty slice binds as SQL NULL and `isUsable` reads it as a declared
    // but unusable credential — so the field must not be materialised.
    const saved = serializeWebSearchProviders(rows({ selfhosted: SELFHOSTED }))
    expect(savedProvider(saved, 'selfhosted')).not.toHaveProperty('key')
    expect(Object.keys(savedProvider(saved, 'selfhosted'))).not.toContain('key')
    expect(JSON.stringify(saved)).not.toContain('"key"')
  })

  it('a backend rejection message is surfaced on the row, not swallowed', () => {
    // What the parent does with a rejected save: pin the message onto
    // the row whose name it mentions, verbatim.
    const parsed = rows({ tinyfish: TINYFISH, selfhosted: SELFHOSTED })
    const rejection = "web_search provider 'tinyfish': url host 127.0.0.1 is not public"
    const errors = webSearchRowErrorsFromMessage(rejection, parsed)
    expect(errors).toEqual({ tinyfish: rejection })

    // The section renders it on THAT row — not as a generic failure, and
    // not on the other row.
    const wrapper = mount(WebSearchSection, {
      props: { modelValue: parsed, errors },
    })
    const onRow = wrapper.find('[data-row-id="tinyfish"] [data-testid="row-error-tinyfish"]')
    expect(onRow.exists()).toBe(true)
    expect(onRow.text()).toBe(rejection)
    expect(
      wrapper.find('[data-row-id="selfhosted"] [data-testid="row-error-selfhosted"]').exists(),
    ).toBe(false)
    // No invented generic banner anywhere in the section.
    expect(wrapper.text()).not.toContain('Save failed')
  })

  it('reports no row error when the rejection names no provider', () => {
    const parsed = rows({ tinyfish: TINYFISH })
    expect(webSearchRowErrorsFromMessage('Save failed: 500 internal error', parsed)).toEqual({})
  })

  // ─── Round-trip ──────────────────────────────────────────────────────────

  it('a provider round-trips through parse then serialize unchanged', () => {
    const saved = serializeWebSearchProviders(rows({ tinyfish: TINYFISH }))
    expect(saved).toEqual({ tinyfish: TINYFISH })
  })

  it('a self-hosted provider round-trips with no key field invented', () => {
    const saved = serializeWebSearchProviders(rows({ selfhosted: SELFHOSTED }))
    expect(saved).toEqual({ selfhosted: SELFHOSTED })
  })

  it('omits enabled when true and keeps enabled: false', () => {
    // Omit-when-true, matching serializeMcpServers: the backend defaults
    // `enabled` to true, so writing the default only adds churn.
    const on = serializeWebSearchProviders(rows({ selfhosted: SELFHOSTED }))
    expect(savedProvider(on, 'selfhosted')).not.toHaveProperty('enabled')

    const off = serializeWebSearchProviders(
      parseWebSearchProviders({ selfhosted: { ...SELFHOSTED, enabled: false } }),
    )
    expect(savedProvider(off, 'selfhosted').enabled).toBe(false)
  })

  it('omits the whole web_search key when the list is empty', () => {
    expect(serializeWebSearchProviders([])).toBeUndefined()
    // A half-filled row the user abandoned has no name, so it never
    // reaches the wire.
    const blank: WebSearchProviderRow = {
      id: 'new-1',
      name: '',
      url: '',
      key: '',
      curl: '',
      description: '',
      enabled: true,
    }
    expect(serializeWebSearchProviders([blank])).toBeUndefined()
  })

  // ─── Row editing ─────────────────────────────────────────────────────────

  it('edits a field in place without disturbing the others', async () => {
    const parsed = rows({ tinyfish: TINYFISH })
    const wrapper = mount(WebSearchSection, { props: { modelValue: parsed } })
    await wrapper
      .find('[data-row-id="tinyfish"] [data-testid="url-input"]')
      .setValue('https://api.tinyfish.example')
    const next = rowByName(lastRows(wrapper), 'tinyfish')
    expect(next.url).toBe('https://api.tinyfish.example')
    expect(next.key).toBe(MASKED)
    expect(next.curl).toBe(TINYFISH.curl)
  })

  it('toggles enabled and removes a row by id', async () => {
    const parsed = rows({ tinyfish: TINYFISH, selfhosted: SELFHOSTED })
    const wrapper = mount(WebSearchSection, { props: { modelValue: parsed } })

    await wrapper.find('[data-row-id="tinyfish"] [data-testid="toggle-btn"]').trigger('click')
    expect(rowByName(lastRows(wrapper), 'tinyfish').enabled).toBe(false)

    await wrapper.find('[data-row-id="selfhosted"] [data-testid="delete-btn"]').trigger('click')
    expect(lastRows(wrapper).map((r) => r.name)).toEqual(['tinyfish'])
  })

  // ─── Host pin + {key} rules, checked before the row reaches the backend ─

  it('flags a pinned URL the backend would refuse', () => {
    // The same matrix `isNonPublicHost` refuses in
    // `web_search_curl.zig`, plus the scheme rule.
    const badUrls = [
      'http://api.search.tinyfish.ai', // http scheme
      'https://127.0.0.1', // loopback
      'https://10.1.2.3', // private 10/8
      'https://172.16.0.5', // private 172.16/12
      'https://192.168.1.10', // private 192.168/16
      'https://169.254.169.254', // link-local / cloud metadata
      'https://localhost:8443', // localhost by name
      'https://box.internal', // .internal suffix
    ]
    for (const url of badUrls) {
      const parsed = parseWebSearchProviders({ p: { url, curl: 'https://x.example?q=1' } })
      expect(validateWebSearchRows(parsed).p).toBeTruthy()
    }
  })

  it('accepts a public https host pin', () => {
    const parsed = parseWebSearchProviders({
      p: { url: 'https://api.example.com', curl: 'https://api.example.com?q=1' },
    })
    expect(validateWebSearchRows(parsed)).toEqual({})
  })

  it('requires {key} in curl exactly when a key is set', () => {
    const withKeyNoPlaceholder = parseWebSearchProviders({
      p: { url: 'https://a.example', key: 'abc', curl: 'https://a.example?q=1' },
    })
    expect(validateWebSearchRows(withKeyNoPlaceholder).p).toContain('{key}')

    const noKeyWithPlaceholder = parseWebSearchProviders({
      p: { url: 'https://a.example', curl: 'https://a.example?q=1&k={key}' },
    })
    expect(validateWebSearchRows(noKeyWithPlaceholder).p).toContain('{key}')

    const consistent = parseWebSearchProviders({
      p: { url: 'https://a.example', key: 'abc', curl: 'https://a.example?q=1&k={key}' },
    })
    expect(validateWebSearchRows(consistent)).toEqual({})
  })

  it('does not block the save over an untouched added row', () => {
    const parsed = [...rows({ tinyfish: TINYFISH })]
    parsed.push({
      id: 'new-9',
      name: '',
      url: '',
      key: '',
      curl: '',
      description: '',
      enabled: true,
    })
    expect(validateWebSearchRows(parsed)).toEqual({})
  })
})

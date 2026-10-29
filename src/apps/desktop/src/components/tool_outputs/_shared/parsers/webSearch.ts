import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'

// ─── web_search ──────────────────────────────────────────────────────────── Parses the JSON
// `data` payload produced by `exec_web_search` in `src/agentic_loop/tools_exec_web_search.zig`.
/** The nine reasons a `web_search` envelope can fail, as the card spells them. */
export type WebSearchErrorFlag =
  | 'configured'
  | 'unknown_provider'
  | 'host_mismatch'
  | 'invalid_curl'
  | 'exhausted'
  | 'unsafe_pinned_url'
  | 'response_too_large'
  | 'http_status'
  | 'transport'

/** An alternative provider, as an error envelope names it. Never carries a key. */
export interface WebSearchProviderRef {
  name: string
  url: string
}

export interface ParsedWebSearchError {
  /** The backend's sentence, verbatim. */
  message: string
  /**    * Which reasons this envelope claims, in a fixed order so two renderings of the same failure
   * never disagree. `transport` is the residual: it is the one failure with no key of its own, so a
   * flagless error is reported as it. Every other flag is read off a key the backend sets. */
  flags: WebSearchErrorFlag[]
  /** True only for `configured:false` — nothing is set up in Settings yet. */
  configured: boolean
  /** `unknown_provider`'s alternatives, so the card can name who IS available. */
  available: WebSearchProviderRef[]
  /** `exhausted`'s alternatives — the providers worth retrying with. */
  otherProviders: WebSearchProviderRef[]
  /** `host_mismatch`: the host the user pinned, and the one the curl asked for. */
  pinnedHost: string | null
  requestedHost: string | null
  /** `http_status`'s number; null for every other reason. */
  httpStatus: number | null
}

export interface ParsedWebSearch {
  /** The provider that ran. Null on `configured`/`unknown_provider` failures. */
  provider: string | null
  /** The provider's HTTP status on success; null on failure. */
  status: number | null
  /** The provider's payload, verbatim. NEVER interpreted — see D13. */
  response: unknown
  /** True when the envelope carries no `error`. */
  success: boolean
  error: ParsedWebSearchError | null
}

/** Read a list of alternative providers. Accepts both spellings the backend
 * and the plan use: `[{name,url}]` objects, and a bare `["tinyfish"]` of names. */
function providerRefs(o: Record<string, unknown>, key: string): WebSearchProviderRef[] {
  const raw = o[key]
  if (!Array.isArray(raw)) return []
  const refs: WebSearchProviderRef[] = []
  for (const item of raw) {
    if (typeof item === 'string') {
      if (item !== '') refs.push({ name: item, url: '' })
      continue
    }
    const r = asRecord(item)
    const name = strField(r, 'name')
    if (name === '') continue
    refs.push({ name, url: strField(r, 'url') })
  }
  return refs
}

/** Typed view of a `web_search` failure envelope. `transport` when nothing claims it. */
export function parseWebSearchError(o: Record<string, unknown>): ParsedWebSearchError {
  const configured = o.configured === false
  const unknownProvider = boolField(o, 'unknown_provider', false)
  const hostMismatch = boolField(o, 'host_mismatch', false)
  const invalidCurl = boolField(o, 'invalid_curl', false)
  const exhausted = boolField(o, 'exhausted', false)
  const unsafePinnedUrl = boolField(o, 'unsafe_pinned_url', false)
  const responseTooLarge = boolField(o, 'response_too_large', false)
  const httpStatus = numOrNullField(o, 'http_status')

  const flags: WebSearchErrorFlag[] = []
  if (configured) flags.push('configured')
  if (unknownProvider) flags.push('unknown_provider')
  if (hostMismatch) flags.push('host_mismatch')
  if (invalidCurl) flags.push('invalid_curl')
  if (exhausted) flags.push('exhausted')
  if (unsafePinnedUrl) flags.push('unsafe_pinned_url')
  if (responseTooLarge) flags.push('response_too_large')
  if (httpStatus !== null) flags.push('http_status')
  if (flags.length === 0) flags.push('transport')

  return {
    message: strField(o, 'error'),
    flags,
    configured,
    available: unknownProvider ? providerRefs(o, 'available') : [],
    otherProviders: exhausted ? providerRefs(o, 'other_providers') : [],
    pinnedHost: strOrNullField(o, 'pinned_host'),
    requestedHost: strOrNullField(o, 'requested_host'),
    httpStatus,
  }
}

/** The exec wrapper reports a failure in TWO places: the envelope's `error` field, and — for the
 * reasons the model can recover from on its own — the whole inner JSON envelope as that field's
 * TEXT. */
export function parseWebSearchErrorText(text: string): ParsedWebSearchError {
  const o = asRecord(text)
  if (typeof o.error === 'string' && Object.keys(o).length > 1) return parseWebSearchError(o)
  return {
    message: text,
    flags: [],
    configured: false,
    available: [],
    otherProviders: [],
    pinnedHost: null,
    requestedHost: null,
    httpStatus: null,
  }
}

export function parseWebSearch(data: unknown): ParsedWebSearch {
  const o = unwrapDataRecord(data)
  const message = strOrNullField(o, 'error')
  if (message !== null) {
    return {
      provider: strOrNullField(o, 'provider'),
      status: null,
      response: null,
      success: false,
      error: parseWebSearchError(o),
    }
  }
  return {
    provider: strOrNullField(o, 'provider'),
    status: numOrNullField(o, 'status'),
    response: 'response' in o ? o.response : null,
    success: true,
    error: null,
  }
}

// ─── list_web_search_providers ───────────────────────────────────────────── The
// `exec_list_web_search_providers` payload (D14):
// {"providers":[{"name":"tinyfish","url":"https://api.search.tinyfish.ai".
export interface ParsedSearchProviderEntry {
  name: string
  url: string
  description: string
  /** The editable template. Contains `{key}`, never the key itself. */
  curl: string
}

export interface ParsedListSearchProviders {
  providers: ParsedSearchProviderEntry[]
}

export function parseListWebSearchProviders(data: unknown): ParsedListSearchProviders {
  const o = unwrapDataRecord(data)
  const raw = Array.isArray(o.providers) ? o.providers : []
  const providers: ParsedSearchProviderEntry[] = []
  for (const item of raw) {
    const r = asRecord(item)
    const name = strField(r, 'name')
    // A nameless row has nothing to key a settings edit on.
    if (name === '') continue
    providers.push({
      name,
      url: strField(r, 'url'),
      description: strField(r, 'description'),
      curl: strField(r, 'curl'),
    })
  }
  return { providers }
}

/**
 * webSearchProviders — the parser/serializer pair for the top-level
 * `web_search` key in config.json.
 *
 * The wire shape is a map of provider name to `PabrikWebSearchProvider`
 * (see `api/index.ts`). The UI edits it as a LIST of rows, because a
 * provider's name is editable in place and an object map cannot express
 * "the key I am currently typing" without a dance. `parse` hydrates the
 * list, `serialize` writes it back.
 *
 * Three properties this pair guarantees, all of which the backend
 * depends on:
 *
 * 1. **`key` is omitted, never emptied.** A self-hosted provider has no
 *    credential; `""` is not the same thing (an empty slice binds as SQL
 *    NULL and `isUsable` treats a declared-but-blank credential as
 *    unusable).
 * 2. **A masked key round-trips unchanged.** `key` may arrive from the
 *    API as an obfuscation string such as `sk••••7f2` rather than as the
 *    secret. Sending it back verbatim is a no-op on the server;
 *    replacing it with `""` would silently destroy the stored secret.
 *    This module therefore never invents a key value — it only decides
 *    whether to emit the one it was given.
 * 3. **`curl` is stored without the secret.** It carries the literal text
 *    `{key}` where the credential goes, never the credential itself.
 *
 * `enabled` is omit-when-true on the wire, mirroring
 * `serializeMcpServers` and the backend's default: only `false` is ever
 * written, so a save never adds churn to a config that relies on the
 * default.
 */
import type { PabrikWebSearchProvider } from '../../api'

/** The literal placeholder `curl` must contain when a key is set. */
export const KEY_PLACEHOLDER = '{key}'

/** Editable row model for one provider. `id` is stable UI identity and is NEVER written to
 * config.json — the map key is `name`. */
/** It exists because `name` is an editable text input: keying Vue's `:key` on it would destroy and
 * rebuild the input node on every keystroke, dropping focus mid-word. */
export interface WebSearchProviderRow {
  /** Stable per-row identity (Vue `:key`, error lookup). Not on the wire. */
  id: string
  /** Provider name — the map key, and what the agent passes to `web_search`. */
  name: string
  /** Host pin. https, never loopback/private/link-local. */
  url: string
  /** Credential, or the backend's mask of it. `''` means "no credential". */
  key: string
  /** Request template carrying `{key}` where the credential goes. */
  curl: string
  /** Optional "when to prefer this provider" note. */
  description: string
  /** Defaults to true; missing renders as enabled. */
  enabled: boolean
}

// Monotonic counter for rows the user adds in the UI. Parsed rows take
// their id from the map key they were stored under, so the `new-` prefix
// keeps the two namespaces from ever colliding.
let newRowSeq = 0

/** A blank row for the "+ Add provider" button. */
export function createWebSearchProviderRow(): WebSearchProviderRow {
  newRowSeq += 1
  return {
    id: `new-${newRowSeq}`,
    name: '',
    url: '',
    key: '',
    curl: '',
    description: '',
    enabled: true,
  }
}

/** Hydrate the editable list from the config's `web_search` map.
 * `null`/absent yields `[]` — same contract as `parseMcpServers`. */
export function parseWebSearchProviders(
  raw: Record<string, PabrikWebSearchProvider> | null | undefined,
): WebSearchProviderRow[] {
  if (!raw) return []
  const out: WebSearchProviderRow[] = []
  for (const [name, provider] of Object.entries(raw)) {
    if (!provider || typeof provider !== 'object') continue
    out.push({
      id: name,
      name,
      url: typeof provider.url === 'string' ? provider.url : '',
      // The backend masks this on GET. Whatever arrives is what gets
      // sent back — see property 2 in the module header.
      key: typeof provider.key === 'string' ? provider.key : '',
      curl: typeof provider.curl === 'string' ? provider.curl : '',
      description: typeof provider.description === 'string' ? provider.description : '',
      // Missing means enabled, matching `WebSearchProviderEntry.enabled`
      // defaulting to true.
      enabled: provider.enabled !== false,
    })
  }
  out.sort((a, b) => a.name.localeCompare(b.name))
  return out
}

/**  * Write the editable list back to the config's `web_search` map. `undefined` means "omit the key
 * entirely" — the same signal the sibling `serializeMcpServers` uses, and the one
 * `usePabrikConfig`'s diff reads as "no change". */
export function serializeWebSearchProviders(
  rows: WebSearchProviderRow[],
): Record<string, PabrikWebSearchProvider> | undefined {
  const out: Record<string, PabrikWebSearchProvider> = {}
  for (const row of rows) {
    const name = row.name.trim()
    if (!name) continue
    // Duplicate names would collapse into one map key. The backend's
    // parser keeps the FIRST entry on a collision, so mirror that rather
    // than letting the last row silently win.
    if (Object.hasOwn(out, name)) continue
    const key = row.key.trim()
    const description = row.description.trim()
    out[name] = {
      url: row.url.trim(),
      curl: row.curl.trim(),
      ...(key ? { key } : {}),
      ...(description ? { description } : {}),
      ...(row.enabled === false ? { enabled: false as const } : {}),
    }
  }
  return Object.keys(out).length ? out : undefined
}

// ─── Host pin checks ──────────────────────────────────────────────────────── A TS port of
// `hostOfUrl` / `isNonPublicHost` / `checkHostPolicy` from
// `src/modules/agent/tools/web_search_curl.zig`.
// Hand-rolled rather than `new URL` so a malformed URL produces a message instead of a thrown
// `TypeError` from inside an input handler, and so the host rules stay line-for-line comparable
// with the backend's.
/** The `host[:port]` of a URL, or `''` when there is none. */
function hostOfUrl(url: string): string {
  const schemeEnd = url.indexOf('://')
  let rest = schemeEnd >= 0 ? url.slice(schemeEnd + 3) : url
  const end = rest.search(/[/?#]/)
  if (end >= 0) rest = rest.slice(0, end)
  const at = rest.lastIndexOf('@')
  if (at >= 0) rest = rest.slice(at + 1)
  return rest
}

function endsWithIgnoreCase(haystack: string, needle: string): boolean {
  if (haystack.length < needle.length) return false
  return haystack.slice(-needle.length).toLowerCase() === needle.toLowerCase()
}

/**  * True when `host` names a loopback, link-local, private or otherwise non-public address — a cloud
 * metadata endpoint, most of all, since a key sent to `169.254.169.254` is a stolen key. */
export function isNonPublicHost(host: string): boolean {
  let h = host
  if (h.startsWith('[')) {
    const close = h.indexOf(']')
    if (close < 0) return true // malformed
    return isNonPublicHost(h.slice(1, close))
  }
  const colon = h.lastIndexOf(':')
  if (colon >= 0) {
    // More than one colon and no brackets is a bare IPv6 literal, which
    // an https URL must bracket.
    if (h.split(':').length - 1 > 1) return true
    h = h.slice(0, colon)
  }
  if (h.length === 0) return true

  if (h.toLowerCase() === 'localhost') return true
  if (endsWithIgnoreCase(h, '.localhost')) return true
  if (endsWithIgnoreCase(h, '.local')) return true
  if (endsWithIgnoreCase(h, '.internal')) return true

  if (h === '::1' || h === '::') return true

  // IPv4 dotted quad. Anything that is not four decimal octets is a
  // hostname, which is not decidable here.
  const quad = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h)
  if (!quad) return false
  const a = Number(quad[1])
  const b = Number(quad[2])
  const c = Number(quad[3])
  const d = Number(quad[4])
  if (a > 255 || b > 255 || c > 255 || d > 255) return false
  if (a === 0) return true // 0.0.0.0/8 "this host"
  if (a === 127) return true // loopback
  if (a === 10) return true // private
  if (a === 172 && b >= 16 && b <= 31) return true // private
  if (a === 192 && b === 168) return true // private
  if (a === 169 && b === 254) return true // link-local / metadata
  if (a === 100 && b >= 64 && b <= 127) return true // CGNAT
  if (a >= 224) return true // multicast + reserved
  return false
}

/** The message for a URL the backend will refuse to pin, or `null` if fine. */
export function urlPinError(url: string): string | null {
  const trimmed = url.trim()
  if (!trimmed) return 'URL is required'
  const schemeEnd = trimmed.indexOf('://')
  if (schemeEnd <= 0) return 'URL must start with https://'
  if (trimmed.slice(0, schemeEnd).toLowerCase() !== 'https') {
    return 'URL must use https — the backend refuses any other scheme'
  }
  if (trimmed.includes('@')) return 'URL must not carry userinfo (user:pass@host)'
  const host = hostOfUrl(trimmed)
  if (!host) return 'URL must name a host'
  if (isNonPublicHost(host)) {
    return 'URL must not point at a loopback, private or link-local host'
  }
  return null
}

// ─── Row validation ─────────────────────────────────────────────────────────
/** Per-row messages keyed by `WebSearchProviderRow.id`, mirroring the rules the backend enforces on
 * `web_search`. One message per row: the first rule that fails, so the user is not handed a wall of
 * text about a row they are still halfway through typing. */
/** Exported as a pure function so the parent can call it before writing `web_search` into the
 * config snapshot — the tests drive it directly. */
export function validateWebSearchRows(rows: WebSearchProviderRow[]): Record<string, string> {
  const errors: Record<string, string> = {}
  for (const row of rows) {
    const message = validateWebSearchRow(row)
    if (message) errors[row.id] = message
  }
  return errors
}

function validateWebSearchRow(row: WebSearchProviderRow): string | null {
  // A row the user added and never filled in is not an error: it has no name, so
  // `serializeWebSearchProviders` drops it and it never reaches the wire.
  // Blocking the whole settings save over a placeholder row would be a worse failure than the one
  // we are guarding against.
  const untouched =
    !row.name.trim() &&
    !row.url.trim() &&
    !row.key.trim() &&
    !row.curl.trim() &&
    !row.description.trim()
  if (untouched) return null
  if (!row.name.trim()) return 'Name is required'
  const pin = urlPinError(row.url)
  if (pin) return pin
  const curl = row.curl.trim()
  if (!curl) return 'curl is required'
  const key = row.key.trim()
  const hasPlaceholder = curl.includes(KEY_PLACEHOLDER)
  if (key && !hasPlaceholder) {
    return `curl must contain ${KEY_PLACEHOLDER} where the key goes`
  }
  if (!key && hasPlaceholder) {
    return `curl must not contain ${KEY_PLACEHOLDER} when no key is set`
  }
  return null
}

/** Route a rejected-save message onto the row it names. The settings save is one PUT of the whole
 * config, so a provider the backend refuses comes back as a single string. */
/** Dropping that into a generic toast would leave the user hunting for which of N rows is broken —
 * the failure would be indistinguishable from a transport error. */
/** This keeps the message verbatim and pins it to the row whose name it mentions; a message that
 * names no row yields `{}` and the caller falls back to the global notification. */
export function webSearchRowErrorsFromMessage(
  message: string,
  rows: WebSearchProviderRow[],
): Record<string, string> {
  const lower = message.toLowerCase()
  for (const row of rows) {
    const name = row.name.trim()
    if (name && lower.includes(name.toLowerCase())) {
      return { [row.id]: message }
    }
  }
  return {}
}

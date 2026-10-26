/** D2 has no in-browser renderer either, so a `<d2>` block becomes an `<img>` whose src is a
 * D2-capable server URL. Kroki is the public one; it takes base64url(zlib-deflate(source)). */
export const D2_DEFAULT_SERVER = 'https://kroki.io'

/** A trailing slash on the configured value would produce `//d2` — a 404 from most servers. */
const withoutTrailingSlash = (value: string): string => value.replace(/\/+$/, '')

/** `VITE_D2_SERVER` points this at a self-hosted Kroki (or any server serving `/d2/svg/<encoded>`) so
 * diagram source need not leave the box. */
export const resolveD2Server = (): string => {
  const env = (import.meta as { env?: Record<string, string | undefined> }).env
  const value = (env?.VITE_D2_SERVER ?? '').trim()
  return withoutTrailingSlash(value.length > 0 ? value : D2_DEFAULT_SERVER)
}

/** base64url without padding — what Kroki's GET API expects, and what cannot be sent as `+`/`/`. */
const toBase64Url = (bytes: Uint8Array): string => {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Kroki's encoding: base64url of a ZLIB deflate, not PlantUML's raw deflate. The deflate runs
 * through `CompressionStream`, which every current browser has; where it is missing the promise
 * rejects and the caller shows the source instead. */
const deflate = async (source: string): Promise<Uint8Array> => {
  const compressor = new CompressionStream('deflate')
  const writer = compressor.writable.getWriter()
  void writer.write(new TextEncoder().encode(source))
  void writer.close()
  return new Uint8Array(await new Response(compressor.readable).arrayBuffer())
}

export const encodeD2 = async (source: string): Promise<string> => toBase64Url(await deflate(source))

/** The SVG URL for one block. Async — callers await it; `server` is injectable for tests. */
export const d2SvgUrl = async (
  source: string,
  server: string = resolveD2Server(),
): Promise<string> => `${withoutTrailingSlash(server)}/d2/svg/${await encodeD2(source)}`

/** The `||`-delimited media-URL wire format. */
export const MEDIA_URLS_WIRE_DELIMITER = '||'

/** Join staged attachments into the wire string. */
export function joinMediaUrlsWire(urls?: readonly string[]): string {
  return (urls ?? [])
    .map((u) => u.trim())
    .filter((u) => u.length > 0)
    .join(MEDIA_URLS_WIRE_DELIMITER)
}

/** Decode a wire `image_url` / `video_url` / `image_urls` string into the list of URLs a renderer can `<img :src>`. */
export function splitMediaUrlsWire(joined?: string | null): string[] | undefined {
  if (!joined) return undefined
  const parts = joined
    .split('|')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  return parts.length > 0 ? parts : undefined
}

/** Last line of defence for the renderer. */
export function renderableMediaUrls(urls?: readonly string[] | null): string[] {
  return (urls ?? []).filter((u) => typeof u === 'string' && u.trim().length > 0)
}

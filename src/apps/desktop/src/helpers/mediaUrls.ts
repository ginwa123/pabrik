/** The `||`-delimited media-URL wire format. `llm_history.image_url` / `.video_url` (and
 * `workspace_item_tasks.image_urls`) hold a single TEXT column carrying N base64 data URLs. */
export const MEDIA_URLS_WIRE_DELIMITER = '||'

/**  * Join staged attachments into the wire string. Empty / blank entries are dropped so a
 * staged-but-cleared attachment cannot turn into a stray `||` (which the split tolerates, but which
 * would still show up in raw DB dumps and in the `queue_queued` SSE frame). */
export function joinMediaUrlsWire(urls?: readonly string[]): string {
  return (urls ?? [])
    .map((u) => u.trim())
    .filter((u) => u.length > 0)
    .join(MEDIA_URLS_WIRE_DELIMITER)
}

/** Decode a wire `image_url` / `video_url` / `image_urls` string into the list of URLs a renderer
 * can `<img :src>`. */
/** Returns `undefined` — not `[]` — when there is nothing to render, so the caller's
 * `v-if="image_urls?.length > 0"` hides the attachment row entirely instead of drawing an empty
 * container. */
export function splitMediaUrlsWire(joined?: string | null): string[] | undefined {
  if (!joined) return undefined
  const parts = joined
    .split('|')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  return parts.length > 0 ? parts : undefined
}

/** Last line of defence for the renderer. */
/** `splitMediaUrlsWire` already refuses to emit a blank entry, but a `Message` can also arrive from
 * a path this module does not own — a persisted SSE row replayed out of the local chat cache, a
 * future field on the wire, a hand-built message in a test. */
/** `v-for` over such a list would bind `:src=""` and the browser would draw a broken-image icon
 * inside the transcript. Filtering in the template means the `<img>`/`<video>` element only ever
 * gets a non-blob URL, whatever produced the array. */
export function renderableMediaUrls(urls?: readonly string[] | null): string[] {
  return (urls ?? []).filter((u) => typeof u === 'string' && u.trim().length > 0)
}

/**
 * `helpers/mediaUrls` — the `||`-joined media-URL wire format.
 *
 * The fixtures below are the shapes the REAL backend produces, not invented
 * ones:
 *   - `||` is written by `insert_llm_histories` ("Join multiple image URLs
 *     with || delimiter") and documented on `http_response.zig`.
 *   - A single `|` is still what `session_queue_messages.image_url` holds for
 *     anything queued by an older client, and what `queue_queued` re-emits.
 *   - A trailing `||` is accepted by `image_urls_validation.zig`
 *     ("tolerate empty segments between consecutive ||").
 *
 * The regression this file exists for: splitting a `||` string on a single
 * `|` yields an empty element per gap, which the transcript renderer binds to
 * `<img src="">` — a broken-image icon in the middle of the user's images.
 */
import { describe, it, expect } from 'vitest'
import {
  joinMediaUrlsWire,
  renderableMediaUrls,
  splitMediaUrlsWire,
  MEDIA_URLS_WIRE_DELIMITER,
} from '../mediaUrls'

const PNG_A = 'data:image/png;base64,AAA'
const PNG_B = 'data:image/png;base64,BBB'
const JPEG_C = 'data:image/jpeg;base64,CCC'

describe('joinMediaUrlsWire', () => {
  it('joins with the two-pipe delimiter the rest of the codebase uses', () => {
    expect(joinMediaUrlsWire([PNG_A, PNG_B])).toBe(`${PNG_A}${MEDIA_URLS_WIRE_DELIMITER}${PNG_B}`)
    expect(joinMediaUrlsWire([PNG_A, PNG_B, JPEG_C])).toBe(`${PNG_A}||${PNG_B}||${JPEG_C}`)
  })

  it('produces the empty sentinel for no attachments, undefined, or all-blank', () => {
    expect(joinMediaUrlsWire()).toBe('')
    expect(joinMediaUrlsWire([])).toBe('')
    expect(joinMediaUrlsWire(['', '   '])).toBe('')
  })

  it('drops blank entries instead of emitting a stray empty segment', () => {
    expect(joinMediaUrlsWire([PNG_A, '', PNG_B])).toBe(`${PNG_A}||${PNG_B}`)
  })
})

describe('splitMediaUrlsWire', () => {
  it('decodes the ||-joined string the llm_history encoder writes', () => {
    // THE regression. A plain `split('|')` on this input returns three
    // entries — the middle one the empty string — and the renderer turns it
    // into a broken <img>.
    expect(splitMediaUrlsWire(`${PNG_A}||${PNG_B}`)).toEqual([PNG_A, PNG_B])
    expect(splitMediaUrlsWire(`${PNG_A}||${PNG_B}||${JPEG_C}`)).toEqual([PNG_A, PNG_B, JPEG_C])
  })

  it('emits no empty entry for any input that a real writer could produce', () => {
    for (const joined of [
      `${PNG_A}||${PNG_B}`,
      `${PNG_A}||${PNG_B}||${JPEG_C}`,
      `${PNG_A}|${PNG_B}`,
      `${PNG_A}||${PNG_B}||`,
      `||${PNG_A}||${PNG_B}`,
      PNG_A,
    ]) {
      const parts = splitMediaUrlsWire(joined) ?? []
      expect(parts.every((p) => p.length > 0)).toBe(true)
    }
  })

  it('still decodes a single-pipe value left behind by an older client', () => {
    // session_queue_messages.image_url predates the || convention for
    // anything an older build wrote, and `queue_queued` re-emits that raw
    // string. Both spellings must produce the same array.
    expect(splitMediaUrlsWire(`${PNG_A}|${PNG_B}`)).toEqual([PNG_A, PNG_B])
    expect(splitMediaUrlsWire(`${PNG_A}|${PNG_B}`)).toEqual(
      splitMediaUrlsWire(`${PNG_A}||${PNG_B}`),
    )
  })

  it('decodes a single URL with no delimiter at all', () => {
    expect(splitMediaUrlsWire(PNG_A)).toEqual([PNG_A])
  })

  it('tolerates a trailing delimiter, which validateImageUrls also accepts', () => {
    expect(splitMediaUrlsWire(`${PNG_A}||`)).toEqual([PNG_A])
  })

  it('returns undefined — not [] — when there is nothing to render', () => {
    // `v-if="image_urls?.length > 0"` hides the attachment row on undefined.
    // An empty array would render an empty flex row instead.
    expect(splitMediaUrlsWire(undefined)).toBeUndefined()
    expect(splitMediaUrlsWire(null)).toBeUndefined()
    expect(splitMediaUrlsWire('')).toBeUndefined()
    expect(splitMediaUrlsWire('||')).toBeUndefined()
  })

  it('round-trips what joinMediaUrlsWire produced', () => {
    expect(splitMediaUrlsWire(joinMediaUrlsWire([PNG_A, PNG_B, JPEG_C]))).toEqual([
      PNG_A,
      PNG_B,
      JPEG_C,
    ])
  })
})

describe('renderableMediaUrls', () => {
  it('drops blanks from an array that did not come from splitMediaUrlsWire', () => {
    // The renderer guard. A message can reach the template from a path this module does not own (a
    // persisted SSE row replayed from the local chat cache, a future wire field), and `v-for` over
    // a blank entry binds :src="".
    expect(renderableMediaUrls([PNG_A, '', PNG_B])).toEqual([PNG_A, PNG_B])
    expect(renderableMediaUrls(['   ', PNG_A])).toEqual([PNG_A])
  })

  it('returns an empty list rather than undefined so v-for has nothing to iterate', () => {
    expect(renderableMediaUrls(undefined)).toEqual([])
    expect(renderableMediaUrls(null)).toEqual([])
    expect(renderableMediaUrls([])).toEqual([])
  })

  it('agrees with splitMediaUrlsWire on a real wire payload', () => {
    const urls = splitMediaUrlsWire(`${PNG_A}||${PNG_B}||${JPEG_C}`) ?? []
    expect(renderableMediaUrls(urls)).toHaveLength(3)
  })
})

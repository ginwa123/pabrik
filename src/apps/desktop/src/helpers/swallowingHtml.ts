/** Elements whose content the HTML parser reads as raw text up to the matching end tag — and, when
 * the model never writes that end tag, up to the end of the message. Everything after it vanishes. */
const RAW_TEXT_TAGS = [
  'style',
  'script',
  'textarea',
  'title',
  'xmp',
  'iframe',
  'noembed',
  'noframes',
  'noscript',
] as const

/** `<plaintext>` has no end tag at all: every character after it — including the app's own closing
 * tags — becomes text, so it is escaped wherever it appears. */
const PLAINTEXT = /<plaintext(?=[\s/>])/gi

/** One pass escapes only the last unclosed opener per element, so N openers of the same element
 * take N passes; the cap keeps a crafted reply from making that unbounded work. */
const GUARD_PASSES = 16

const isTagBoundary = (ch: string | undefined): boolean =>
  ch === undefined || ch === '' || ch === '>' || ch === '/' || /\s/.test(ch)

/** Index of the last `<tag` that really opens `tag`, not a prefix of `<tagged`. */
const lastOpener = (lower: string, tag: string): number => {
  const needle = `<${tag}`
  let at = lower.lastIndexOf(needle)
  while (at !== -1) {
    if (isTagBoundary(lower[at + needle.length])) return at
    at = at === 0 ? -1 : lower.lastIndexOf(needle, at - 1)
  }
  return -1
}

const escapeAt = (html: string, at: number): string =>
  `${html.slice(0, at)}&lt;${html.slice(at + 1)}`

/** Escapes the `<` of an opener that nothing closes, so it reads as text instead of consuming the
 * rest of the message. */
const escapeUnclosed = (html: string, tag: string): string => {
  const lower = html.toLowerCase()
  const open = lastOpener(lower, tag)
  if (open === -1) return html
  return lower.lastIndexOf(`</${tag}`) > open ? html : escapeAt(html, open)
}

/** An unclosed `<!--` runs to the end of the input — the text after it becomes the comment node's
 * data and never paints — so the opener is escaped like an unclosed tag. */
const escapeUnclosedComment = (html: string): string => {
  const open = html.lastIndexOf('<!--')
  if (open === -1) return html
  return html.lastIndexOf('-->') > open ? html : escapeAt(html, open)
}

const neutralizeOnce = (html: string): string => {
  let out = escapeUnclosedComment(html)
  for (const tag of RAW_TEXT_TAGS) out = escapeUnclosed(out, tag)
  return out
}

/** Make rendered HTML safe to hand to `v-html`: an opener the model left unclosed can no longer
 * swallow the text after it. Closed elements are untouched, so a complete report keeps its look. */
export const neutralizeSwallowingHtml = (html: string): string => {
  if (!html) return html
  let out = html.replace(PLAINTEXT, '&lt;plaintext')
  for (let pass = 0; pass < GUARD_PASSES; pass++) {
    const next = neutralizeOnce(out)
    if (next === out) return out
    out = next
  }
  return out
}

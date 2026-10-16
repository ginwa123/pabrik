/** Navigating one skill's body: the outline and the find box, as pure
 * functions over the raw markdown the detail pane already holds. A
 * section is one `##`/`###` heading, with the line it starts on. */
export interface SkillSection {
  /** The heading text, `#` marks and trailing `#`s stripped. */
  title: string
  /** 1-based line number in the body, so a jump can target it. */
  line: number
  /** 2 for `##`, 3 for `###`. Deeper levels are not outlined. */
  depth: 2 | 3
}

/** The `##`/`###` headings, in document order. Fenced blocks are skipped:
 * a `## Example` inside a fence is sample text, not a section. */
export function extractSections(body: string): SkillSection[] {
  const out: SkillSection[] = []
  let inFence = false
  const lines = body.split('\n')
  for (const [index, line] of lines.entries()) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    if (inFence) continue
    const m = /^(#{2,3})\s+(.*?)\s*#*\s*$/.exec(line)
    if (!m) continue
    const title = m[2]?.trim() ?? ''
    if (title.length === 0) continue
    out.push({ title, line: index + 1, depth: m[1]?.length === 2 ? 2 : 3 })
  }
  return out
}

/** One line of the body that contains the search term. */
export interface SkillBodyHit {
  /** 1-based line number. */
  line: number
  /** The line's text, trimmed, for the result row. */
  text: string
}

/** Every line containing `term`, case-insensitively. An empty term matches
 * nothing: an empty box answering "all 500 lines" is noise. */
export function findInBody(body: string, term: string): SkillBodyHit[] {
  const needle = term.trim().toLowerCase()
  if (needle.length === 0) return []
  const out: SkillBodyHit[] = []
  const lines = body.split('\n')
  for (const [index, text] of lines.entries()) {
    if (text.toLowerCase().includes(needle)) {
      out.push({ line: index + 1, text: text.trim() })
    }
  }
  return out
}

/** How many times `term` occurs in the body, for the "N matches" label. A
 * term appearing twice on one line counts twice. */
export function countBodyMatches(body: string, term: string): number {
  const needle = term.trim().toLowerCase()
  if (needle.length === 0) return 0
  let total = 0
  for (const line of body.split('\n')) {
    const hay = line.toLowerCase()
    let from = 0
    for (;;) {
      const at = hay.indexOf(needle, from)
      if (at === -1) break
      total++
      from = at + needle.length
    }
  }
  return total
}

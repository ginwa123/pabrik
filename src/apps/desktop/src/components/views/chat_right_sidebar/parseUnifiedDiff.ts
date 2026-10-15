export interface ParsedDiffLine {
  type: 'add' | 'remove' | 'context' | 'header' | 'hunk' | 'empty'
  content: string
  oldLineNum?: number
  newLineNum?: number
  lineIndex: number
}

export interface ParsedDiff {
  lines: ParsedDiffLine[]
  added: number
  removed: number
}

function tryParseInt(s: string): number | null {
  const n = parseInt(s, 10)
  return isNaN(n) ? null : n
}

/**  * One `@@ -a,b +c,d @@` header. Module-level and shared by `parseUnifiedDiff` and `countDiffLines`
 * on purpose: two copies of this pattern drift the moment either is edited, and then the row counts
 * stop matching the diff they sit next to. */
const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)?$/

// Pure extraction of GitFileViewer.vue parseUnifiedDiff logic so the
// ChatView-embedded sidebar and the legacy fullscreen viewer share one
// parser. No Vue reactivity here — takes a string, returns data.
export function parseUnifiedDiff(diffText: string): ParsedDiff {
  const lines = diffText.split('\n')
  const parsed: ParsedDiffLine[] = []

  let added = 0
  let removed = 0
  let lineIndex = 0

  let oldLine = 0
  let newLine = 0
  let inHunk = false

  for (const line of lines) {
    if (line.startsWith('diff --git') || line.startsWith('index ')) {
      continue
    }

    const hunkMatch = HUNK_HEADER.exec(line)
    if (hunkMatch) {
      inHunk = true
      oldLine = tryParseInt(hunkMatch[1] ?? '') ?? 1
      newLine = tryParseInt(hunkMatch[2] ?? '') ?? 1

      parsed.push({
        type: 'hunk',
        content: line,
        lineIndex: lineIndex++,
      })
      continue
    }

    if (!inHunk) {
      if (line.startsWith('---') || line.startsWith('+++')) {
        continue
      }
      continue
    }

    if (line.length === 0) {
      parsed.push({
        type: 'empty',
        content: '',
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      continue
    }

    const firstChar = line[0]

    if (firstChar === '+') {
      parsed.push({
        type: 'add',
        content: line.substring(1),
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      added++
      newLine++
    } else if (firstChar === '-') {
      parsed.push({
        type: 'remove',
        content: line.substring(1),
        oldLineNum: oldLine,
        lineIndex: lineIndex++,
      })
      removed++
      oldLine++
    } else if (firstChar === ' ') {
      parsed.push({
        type: 'context',
        content: line.substring(1),
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    } else {
      parsed.push({
        type: 'context',
        content: line,
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    }
  }

  return { lines: parsed, added, removed }
}

export interface DiffLineCounts {
  added: number
  removed: number
}

/**
 * `+added / -removed` for ONE file's diff chunk, without building the line
 * array `parseUnifiedDiff` returns.
 *
 * Why this exists: the file lists want a number per row, and the only diff
 * text they have is the chunk they already hold. Parsing it into
 * `ParsedDiffLine[]` just to read two counters allocates an object per line
 * for a 900-line file — on a 35-file list that is tens of thousands of
 * objects to render two digits.
 *
 * Deliberately mirrors `parseUnifiedDiff`'s line classification (same hunk
 * regex, same "nothing before the first hunk counts" rule) so a row's
 * counts always agree with the diff the center column shows for that file.
 * `\ No newline at end of file` and the `--- / +++` headers are therefore
 * not counted, exactly as in the parser.
 */
export function countDiffLines(diffText: string): DiffLineCounts {
  let added = 0
  let removed = 0
  let inHunk = false

  for (const line of diffText.split('\n')) {
    if (line.startsWith('diff --git') || line.startsWith('index ')) continue
    if (HUNK_HEADER.test(line)) {
      inHunk = true
      continue
    }
    if (!inHunk) continue
    if (line.length === 0) continue
    const firstChar = line[0]
    if (firstChar === '+') added++
    else if (firstChar === '-') removed++
  }

  return { added, removed }
}

export interface SplitDiffFile {
  /** Display path (b/ side, or a/ side for deletions). */
  path: string
  /** 'M' | 'A' | 'D' | 'R' derived from the file header. */
  status: string
  /** Raw unified-diff chunk for this file (includes its headers). */
  text: string
}

// Split a multi-file unified diff (e.g. `gh pr diff` output) into
// per-file chunks at `diff --git` boundaries. Pure: no IO, no Vue.
// Status comes from the header lines: `new file mode` → A,
// `deleted file mode` → D, `similarity index`/`rename from` → R,
// else M. Unparseable leading text (e.g. empty diff) yields [].
export function splitDiffByFile(diffText: string): SplitDiffFile[] {
  const out: SplitDiffFile[] = []
  const lines = diffText.split('\n')
  let start = -1
  const push = (end: number) => {
    if (start < 0) return
    const chunk = lines.slice(start, end).join('\n')
    const header = lines.slice(start, Math.min(start + 8, end)).join('\n')
    let status = 'M'
    if (header.includes('new file mode')) status = 'A'
    else if (header.includes('deleted file mode')) status = 'D'
    else if (header.includes('rename from') || header.includes('similarity index')) status = 'R'
    const first = lines[start] ?? ''
    const m = first.match(/^diff --git a\/(.*) b\/(.*)$/)
    const path = (m?.[2] ?? m?.[1] ?? '').replace(/\/$/, '') || 'unknown'
    out.push({ path, status, text: chunk })
    start = -1
  }
  for (let i = 0; i < lines.length; i++) {
    if (lines[i]?.startsWith('diff --git ')) {
      push(i)
      start = i
    }
  }
  push(lines.length)
  return out.filter((f) => f.text.trim().length > 0)
}

/**  * Center-diff selection payload: panel row click → shell → ChatView. `lines` travel by reference
 * (no copy). `error` set when the worktree fetch failed (PR mode parses inline, so error is always
 * null there). */
export interface DiffSelection {
  path: string
  staged: boolean
  lines: ParsedDiffLine[]
  added: number
  removed: number
  error?: string | null
  /** A new file: its diff already shows every line, so the whole-file scope
   * is satisfied without a request (the control renders locked). */
  untracked?: boolean
}

// Stacked center diff addressing: each section id is `center-diff-<base64url-no-pad path>`, and the
// ?diff= URL param carries the same encoding. btoa throws on non-latin1 paths (unicode), so fall
// back to encodeURIComponent — still deterministic, still matchable.
export function encodePathParam(path: string): string {
  try {
    return btoa(path).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  } catch {
    return encodeURIComponent(path)
  }
}

export function centerDiffSectionId(path: string): string {
  return `center-diff-${encodePathParam(path)}`
}

// Resolve a ?diff= value against the listed paths only — never decode
// blindly into a selection, so stale/garbage params are ignored. Also
// accepts legacy padded btoa (other features link files that way).
export function decodePathParam(param: string, candidates: string[]): string | null {
  for (const c of candidates) {
    if (encodePathParam(c) === param) return c
  }
  try {
    const padded = param.replace(/-/g, '+').replace(/_/g, '/')
    const decoded = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
    return candidates.find((c) => c === decoded) ?? null
  } catch {
    return null
  }
}

// Scroll the stacked section for a path into view. Returns false when
// the section isn't mounted (list not loaded yet) — callers treat that
// as "nothing to scroll to", never a throw.
export function scrollToSectionElement(path: string): boolean {
  if (typeof document === 'undefined') return false
  const el = document.getElementById(centerDiffSectionId(path))
  if (!el) return false
  el.scrollIntoView({ block: 'start' })
  return true
}

export function escapeDiffHtml(line: string): string {
  if (!line) return '&nbsp;'
  return line.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}

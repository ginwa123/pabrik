import { describe, expect, it } from 'vitest'
import {
  countDiffLines,
  escapeDiffHtml,
  parseUnifiedDiff,
} from '../chat_right_sidebar/parseUnifiedDiff'

const SAMPLE = `diff --git a/foo.txt b/foo.txt
index 123..456 100644
--- a/foo.txt
+++ b/foo.txt
@@ -1,3 +1,4 @@
 line1
-old
+new
+added
 line3`

describe('parseUnifiedDiff', () => {
  it('parses hunk header and counts added/removed', () => {
    const out = parseUnifiedDiff(SAMPLE)
    expect(out.added).toBe(2)
    expect(out.removed).toBe(1)
    expect(out.lines.some((l) => l.type === 'hunk')).toBe(true)
  })

  it('tracks line numbers across hunk', () => {
    const out = parseUnifiedDiff(SAMPLE)
    const add = out.lines.find((l) => l.type === 'add')
    const remove = out.lines.find((l) => l.type === 'remove')
    expect(add?.newLineNum).toBeDefined()
    expect(remove?.oldLineNum).toBeDefined()
  })

  it('returns empty lines for empty diff', () => {
    const out = parseUnifiedDiff('')
    expect(out.lines).toEqual([])
    expect(out.added).toBe(0)
    expect(out.removed).toBe(0)
  })

  it('skips git headers before first hunk', () => {
    const out = parseUnifiedDiff('diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n')
    expect(out.lines).toEqual([])
  })

  it('escapes html in diff lines', () => {
    expect(escapeDiffHtml('<b>&')).toBe('&lt;b&gt;&amp;')
    expect(escapeDiffHtml('')).toBe('&nbsp;')
  })
})

// A chunk with two hunks, a `\ No newline` marker, and a rename header — the shapes that make a naive `+`/`-` line count disagree with the parser.
const MULTI_HUNK = `diff --git a/x.txt b/x.txt
similarity index 90%
rename from old.txt
rename to x.txt
index 123..456 100644
--- a/old.txt
+++ b/x.txt
@@ -1,3 +1,3 @@
 keep
-was
+now
@@ -10,2 +10,4 @@
 tail
+one
+two
\\ No newline at end of file`

describe('countDiffLines', () => {
  it('counts added and removed lines across every hunk', () => {
    expect(countDiffLines(MULTI_HUNK)).toEqual({ added: 3, removed: 1 })
  })

  it('agrees with parseUnifiedDiff on the same chunk', () => {
    // The row counts and the center diff are two views of one chunk; if they ever disagree the panel is lying about its own file.
    const parsed = parseUnifiedDiff(MULTI_HUNK)
    expect(countDiffLines(MULTI_HUNK)).toEqual({
      added: parsed.added,
      removed: parsed.removed,
    })
  })

  it('does not count the --- / +++ headers or the no-newline marker', () => {
    // `--- a/x` and `+++ b/x` both start with -/+ but are headers, and `\ No newline at end of file` starts with neither.
    const headerOnly = 'diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n'
    expect(countDiffLines(headerOnly)).toEqual({ added: 0, removed: 0 })
  })

  it('returns zeros for an empty diff', () => {
    expect(countDiffLines('')).toEqual({ added: 0, removed: 0 })
  })

  it('counts a whole new file as all additions', () => {
    const newFile =
      'diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b'
    expect(countDiffLines(newFile)).toEqual({ added: 2, removed: 0 })
  })

  it('counts a deleted file as all removals', () => {
    const gone =
      'diff --git a/g.txt b/g.txt\ndeleted file mode 100644\n--- a/g.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b'
    expect(countDiffLines(gone)).toEqual({ added: 0, removed: 2 })
  })
})

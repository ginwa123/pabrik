const ESC = 0x1b
const BEL = 0x07
const CSI_FINAL_LOW = 0x40
const CSI_FINAL_HIGH = 0x7e

/** Index just past the terminal REPORT starting at `i` (`i` for typing): `ESC [`
 * to its final byte — DA1, CPR, a mode report, mouse — `ESC ]` to BEL or ST, or
 * any other `ESC x` pair. */
function reportEnd(data: string, i: number): number {
  if (data.charCodeAt(i) !== ESC) return i
  if (i + 1 >= data.length) return data.length
  const kind = data[i + 1]
  if (kind === '[') {
    for (let j = i + 2; j < data.length; j += 1) {
      const c = data.charCodeAt(j)
      if (c >= CSI_FINAL_LOW && c <= CSI_FINAL_HIGH) return j + 1
    }
    return data.length
  }
  if (kind === ']') {
    for (let j = i + 2; j < data.length; j += 1) {
      if (data.charCodeAt(j) === BEL) return j + 1
      if (data.charCodeAt(j) === ESC && data[j + 1] === '\\') return j + 2
    }
    return data.length
  }
  return i + 2
}

/** Keystrokes for one session's console. A `pipe`-backed Windows session has no
 * VT input, so a report can only come back as its visible payload — the literal
 * `[?2004;2$y` on screen. Every pty backend keeps all of its bytes. */
export function inputForBackend(backend: string, data: string): string {
  if (backend !== 'pipe') return data
  let kept = ''
  let i = 0
  while (i < data.length) {
    const end = reportEnd(data, i)
    if (end > i) {
      i = end
      continue
    }
    kept += data[i]
    i += 1
  }
  return kept
}

// Compute the next available placeholder name for a new design page. Mirrors the macOS / Figma
// convention: the very first untitled page is `"Untitled"` (no suffix), every subsequent one is
// `"Untitled N"` where `N` is `max(existing numbers) + 1`.
const UNTITLEDBASE_NAME = 'Untitled'
const UNTITLEDPATTERN = /^Untitled (\d+)$/
export const computeNextUntitledName = (existingPages: ReadonlyArray<{ name: string }>): string => {
  let hasUnnumbered = false
  let maxNumbered = 0
  for (const p of existingPages) {
    if (p.name === UNTITLEDBASE_NAME) {
      hasUnnumbered = true
      continue
    }
    const match = UNTITLEDPATTERN.exec(p.name)
    if (match && match[1]) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > 0 && n > maxNumbered) {
        maxNumbered = n
      }
    }
  }
  // Very first page: no unnumbered, no numbered → "Untitled". Everything else: take maxNumbered +
  // 1. If only an unnumbered "Untitled" exists (maxNumbered === 0), return "Untitled 1" because we
  // can't collide with the existing literal.
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLEDBASE_NAME
  return `${UNTITLEDBASE_NAME} ${maxNumbered + 1}`
}

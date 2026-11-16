// Compute the next available placeholder name for a new design page.
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
  // Very first page: no unnumbered, no numbered → "Untitled".
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLEDBASE_NAME
  return `${UNTITLEDBASE_NAME} ${maxNumbered + 1}`
}

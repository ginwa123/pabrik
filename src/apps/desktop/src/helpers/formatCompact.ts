/** Compact number formatting for dense status surfaces (e.g. the ChatView composer toolbar's token readout). */
export const formatCompactTokens = (n: number): string => {
  if (n >= 1_000_000) {
    const v = n / 1_000_000
    return `${v >= 100 ? Math.round(v) : Math.round(v * 10) / 10}M`
  }
  if (n >= 1000) {
    const v = n / 1000
    return `${v >= 100 ? Math.round(v) : Math.round(v * 10) / 10}k`
  }
  return `${n}`
}

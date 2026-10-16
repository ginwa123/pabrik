/** Compact number formatting for dense status surfaces (e.g. the ChatView composer toolbar's token
 * readout). `82,679 → 82.7k`, `900,000 → 900k`, `1,500,000 → 1.5M`. Values under 1,000 pass through
 * unchanged. */
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

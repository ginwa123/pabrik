/** Extract the `error` field from a JSON error body, if present. */
export function tryParseErrorBody(body: string): string | null {
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') {
      return obj.error
    }
    return null
  } catch {
    return null
  }
}

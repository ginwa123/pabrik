/** Hand `blob` to the browser as a file named `filename` — the same path a link with a
 * `download` attribute takes. The object URL is revoked on the next task, not immediately:
 * revoking in the same tick can cancel the download in some engines. */
export function downloadBlob(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = filename
  anchor.rel = 'noopener'
  anchor.style.display = 'none'
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}

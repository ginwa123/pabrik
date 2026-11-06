/** Keep-append: the editor keys merge into the current URL so the workspace/project/chat context in
 * the path survives a reload. */
export function codeEditorQuery(
  query: Record<string, unknown>,
  path: string,
  line: number | null,
  diff = false,
): Record<string, string> {
  const next: Record<string, string> = {}
  for (const [k, v] of Object.entries(query)) {
    if (typeof v !== 'string' || v.length === 0) continue
    if (k === 'view' || k === 'file' || k === 'line' || k === 'cwd' || k === 'mode') continue
    next[k] = v
  }
  next.view = 'code-editor'
  next.file = path
  // The mode is the tab's identity for a diff: it must never be inherited from the URL it replaced.
  if (diff) next.mode = 'diff'
  if (line !== null) {
    next.line = String(line)
  }
  return next
}

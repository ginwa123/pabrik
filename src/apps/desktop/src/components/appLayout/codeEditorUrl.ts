/** Keep-append: the editor keys merge into the current URL so the workspace/project/chat context in
 * the path survives a reload. */
export function codeEditorQuery(
  query: Record<string, unknown>,
  path: string,
  line: number | null,
): Record<string, string> {
  const next: Record<string, string> = {}
  for (const [k, v] of Object.entries(query)) {
    if (typeof v !== 'string' || v.length === 0) continue
    if (k === 'view' || k === 'file' || k === 'line' || k === 'cwd') continue
    next[k] = v
  }
  next.view = 'code-editor'
  next.file = path
  if (line !== null) {
    next.line = String(line)
  }
  return next
}

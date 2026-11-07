/** Keep-append: the editor keys merge into the current URL so the workspace/project/chat context in
 * the path survives a reload. */
export function codeEditorQuery(
  query: Record<string, unknown>,
  path: string,
  line: number | null,
  diff = false,
  cwd = '',
): Record<string, string> {
  const next: Record<string, string> = {}
  for (const [k, v] of Object.entries(query)) {
    if (typeof v !== 'string' || v.length === 0) continue
    // `tab` names the OLD target: keeping it would point the new file's URL at the previous tab.
    if (
      k === 'view' ||
      k === 'file' ||
      k === 'line' ||
      k === 'cwd' ||
      k === 'mode' ||
      k === 'tab'
    ) {
      continue
    }
    next[k] = v
  }
  next.view = 'code-editor'
  next.file = path
  // The directory the file was resolved against travels with it: that is what gives a relative
  // `file` one absolute key in the strip, and a shared link the cwd the editor needs.
  const inherited = cwd || (typeof query.cwd === 'string' ? query.cwd : '')
  if (inherited.length > 0) next.cwd = inherited
  // The mode is the tab's identity for a diff: it must never be inherited from the URL it replaced.
  if (diff) next.mode = 'diff'
  if (line !== null) {
    next.line = String(line)
  }
  return next
}

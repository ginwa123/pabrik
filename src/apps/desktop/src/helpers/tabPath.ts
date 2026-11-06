/** Path identity for file tabs: one file is one key, whatever spelling and cwd it arrives with. */
export function isAbsolutePath(path: string): boolean {
  return path.startsWith('/') || /^[A-Za-z]:[\\/]/.test(path)
}

/** Collapse `.`, `..` and duplicate separators; the root and the drive prefix survive. */
export function normalisePath(path: string): string {
  if (!path) return ''
  const drive = /^[A-Za-z]:/.exec(path)?.[0] ?? ''
  const rest = path.slice(drive.length)
  const rooted = /^[\\/]/.test(rest)
  const sep = drive ? '\\' : '/'
  const parts: string[] = []
  for (const part of rest.split(/[\\/]+/)) {
    if (!part || part === '.') continue
    if (part === '..') {
      if (parts.length > 0 && parts[parts.length - 1] !== '..') parts.pop()
      else if (!rooted) parts.push('..')
      continue
    }
    parts.push(part)
  }
  const body = parts.join(sep)
  if (rooted) return `${drive}${sep}${body}`
  return drive ? `${drive}${body}` : body
}

/** A tab's file, resolved: a relative path is joined to the cwd, then both are normalised. */
export function resolveTabPath(file: string, cwd: string): string {
  if (!file) return ''
  const joined = isAbsolutePath(file) || !cwd ? file : `${cwd.replace(/[\\/]+$/, '')}/${file}`
  return isAbsolutePath(joined) ? normalisePath(joined) : joined
}

/** Every key one file may already be filed under: its resolved path first, then the spellings it
 * arrived with before a cwd made it absolute. */
export function fileKeyVariants(file: string, cwd: string, diff: boolean): string[] {
  if (!file) return ['file:']
  const prefix = diff ? 'diff:' : 'file:'
  const keys = [resolveTabPath(file, cwd), file, resolveTabPath(file, '')].map(
    (spelling) => `${prefix}${spelling}`,
  )
  return keys.filter((key, index) => keys.indexOf(key) === index)
}

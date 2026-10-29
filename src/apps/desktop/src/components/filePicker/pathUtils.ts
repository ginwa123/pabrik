// ─── Helpers ───────────────────────────────────────────────────────────────
// ── Cross-platform path helpers (Windows fix, 2026-09-05) ────────────── POSIX inputs produce
// byte-identical results to the old POSIX-only implementations; see the file header for the rest.
export function isWindowsAbs(path: string): boolean {
  if (!path) return false
  if (/^[A-Za-z]:[\\/]/.test(path)) return true
  if (path.startsWith('\\\\') || path.startsWith('//')) return true
  return false
}

/** True for any absolute path on either platform. */
export function isAbsPath(path: string): boolean {
  return path.startsWith('/') || isWindowsAbs(path)
}

/** Split on BOTH separators, dropping empties. */
export function splitSegments(path: string): string[] {
  return path.split(/[\\/]/).filter(Boolean)
}

/** Basename across both separators. */
export function basenameOf(path: string): string {
  const segs = splitSegments(path)
  return segs.length > 0 ? (segs[segs.length - 1] as string) : path
}

/** True when `path` is a filesystem root: `/`, `C:\`, `C:/`, `C:`, or a UNC share root. */
export function isRootPath(path: string): boolean {
  if (path === '/' || path === '') return true
  if (/^[A-Za-z]:[\\/]?$/.test(path)) return true
  if (/^[\\/]{2}[^\\/]+[\\/]+[^\\/]+\/?$/.test(path)) return true
  return false
}

export function parentPath(path: string): string {
  if (!path || path === '/') return '/'
  // Windows drive root (`C:\`, `C:/`, `C:`) and UNC share roots have no
  // parent in this picker — step out to the system root (''), which the
  // callers resolve via getSystemFolder (backend home / USERPROFILE).
  if (/^[A-Za-z]:[\\/]?$/.test(path)) return ''
  if (/^[\\/]{2}[^\\/]+[\\/]+[^\\/]+\/?$/.test(path)) return ''
  // Strip ONE trailing run of separators (never the root itself).
  const stripped = path.length > 1 ? path.replace(/[\\/]+$/, '') : path
  if (/^[A-Za-z]:$/.test(stripped)) return ''
  if (stripped === '' || stripped === '/') return '/'
  const idx = Math.max(stripped.lastIndexOf('/'), stripped.lastIndexOf('\\'))
  if (idx <= 0) return '/'
  const parent = stripped.substring(0, idx)
  // A bare drive (`C:`) isn't navigable — surface the drive root instead
  // so the ancestor chain keeps the `C:\` level.
  if (/^[A-Za-z]:$/.test(parent)) return `${parent}\\`
  return parent || '/'
}

export function parseBreadcrumb(path: string): Array<{ name: string; path: string }> {
  if (!path || path === '/') return []
  // Windows drive: preserve the drive root and join with backslashes so
  // every crumb stays a valid absolute the backend can list.
  const driveMatch = /^[A-Za-z]:/.exec(path)
  if (driveMatch) {
    const drive = driveMatch[0]!
    const rest = splitSegments(path.slice(drive.length))
    const segments: Array<{ name: string; path: string }> = []
    let acc = `${drive}\\`
    segments.push({ name: drive, path: acc })
    for (const part of rest) {
      acc = acc.replace(/[\\/]+$/, '') + '\\' + part
      segments.push({ name: part, path: acc })
    }
    return segments
  }
  // Windows UNC: `\\server\share` is the root crumb.
  const uncMatch = /^[\\/]{2}([^\\/]+)[\\/]+([^\\/]+)/.exec(path)
  if (uncMatch) {
    const root = `\\\\${uncMatch[1]!}\\${uncMatch[2]!}`
    const rest = splitSegments(path.slice(uncMatch[0]!.length))
    const segments: Array<{ name: string; path: string }> = [{ name: root, path: `${root}\\` }]
    let acc = root
    for (const part of rest) {
      acc = acc + '\\' + part
      segments.push({ name: part, path: acc })
    }
    return segments
  }
  // POSIX (unchanged legacy behavior).
  const segments: Array<{ name: string; path: string }> = []
  const parts = path.split('/').filter(Boolean)
  let acc = ''
  for (const part of parts) {
    acc += '/' + part
    segments.push({ name: part, path: acc })
  }
  return segments
}

// ─── Address-bar normalization ──────────────────────────────────────────── Accepts whatever the
// user typed in the address input and returns a canonical absolute path, or `null` when the input
// is unusable.
export function normalizeAddressInput(raw: string, currentPath: string): string | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  if (trimmed === '~' || trimmed === '~/') return '/'

  // Windows absolute (drive or UNC). Previously these fell through to the
  // relative branch and came out as `/C:\...` garbage — the exact mixed
  // shape that ended up persisted as workspace_items.path on Windows.
  if (isWindowsAbs(trimmed)) {
    let out: string
    if (trimmed.startsWith('\\\\') || trimmed.startsWith('//')) {
      out = trimmed.slice(0, 2) + trimmed.slice(2).replace(/[\\/]+/g, '\\')
    } else {
      out = trimmed.replace(/[\\/]+/g, (m) => (m.includes('\\') ? '\\' : '/'))
    }
    // Strip a trailing separator unless the whole thing is a root.
    if (!isRootPath(out)) out = out.replace(/[\\/]+$/, '')
    return out || null
  }

  // Already absolute (starts with '/'). Collapse runs of slashes and
  // strip a trailing slash unless the result would be empty.
  if (trimmed.startsWith('/')) {
    const collapsed = trimmed.replace(/\/+/g, '/').replace(/(.)\/$/, '$1')
    return collapsed || '/'
  }

  // Relative path: resolve against currentPath so a bare "docs" jumps into "./docs" inside the
  // current view instead of being treated as invalid.
  const base = currentPath
  if (trimmed.startsWith('./') || trimmed.startsWith('../')) {
    const rel = trimmed.replace(/^\.\//, '')
    return joinRelative(base, rel)
  }
  return joinRelative(base, trimmed)
}

// Relative-path join with `..` support. Preserves a Windows drive/UNC prefix on the base so `notes`
// from `C:\Users\ginwa` resolves to `C:\Users\ginwa\notes` (not `/notes`). Purely lexical — no
// filesystem access. POSIX inputs behave exactly like the old POSIX-only version.
export function joinRelative(base: string, rel: string): string {
  const driveMatch = /^[A-Za-z]:/.exec(base)
  const uncMatch = !driveMatch ? /^[\\/]{2}[^\\/]+[\\/]+[^\\/]+/.exec(base) : null
  const isWindowsBase = !!driveMatch || !!uncMatch
  const baseRest = driveMatch
    ? base.slice(driveMatch[0]!.length)
    : uncMatch
      ? base.slice(uncMatch[0]!.length)
      : base
  const baseParts = baseRest.split(/[\\/]/).filter((p) => p !== '' && p !== '.')
  const relParts = rel.split(/[\\/]/).filter((p) => p !== '.' && p !== '')
  const out = [...baseParts]
  for (const part of relParts) {
    if (part === '..') {
      if (out.length > 0) out.pop()
    } else {
      out.push(part)
    }
  }
  if (!isWindowsBase) return '/' + out.join('/')
  const prefix = driveMatch ? `${driveMatch[0]!}\\` : `${uncMatch![0].replace(/\//g, '\\')}`
  if (out.length === 0) return prefix
  return prefix.replace(/[\\/]+$/, '') + '\\' + out.join('\\')
}

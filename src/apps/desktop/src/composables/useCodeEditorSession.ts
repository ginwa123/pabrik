import { ref } from 'vue'
import type { FolderEntry } from '../api'
import type { OpenInCodeEditorOptions } from './useCodeEditor'

// Single source of truth for the in-app code editor's open-file
// session. Previously this state lived as five loosely-coupled refs
// in AppLayout (file / content / loading / error / requestedLine)
// plus ad-hoc `btoa`/`atob` calls at the open and restore sites.
// That split caused three user-visible bugs:
//
//   1. The footer joined `cwd + '/' + filePath` even when filePath
//      was already absolute (doubled path in the footer).
//   2. Raw `btoa` output (`+/=`) was stuffed into the URL query —
//      not URL-safe, breaks on copy/paste through clients that
//      decode `+` as space.
//   3. Silent blanks: a missing cwd early-returned with no error,
//      and a bad base64 link nulled the file with no error, so the
//      editor mounted (or unmounted) with an empty view.
//
// This composable owns the whole open → fetch → URL-sync → restore
// cycle. AppLayout instantiates it once and binds its template to the
// exposed refs; all openers (sidebar explorer, diff views, tool-output
// cards) keep calling the injected `openInCodeEditor` which now
// delegates here. The viewer is read-only, so there is no save step:
// the backend registers no write route (only `GET /api/system/folder`).
// An absolute path is shown as-is; only relative paths are joined with the cwd. Mirrors the backend
// `is_abs` check in src/http_handlers/system_folder.zig (POSIX `/`, Windows drive `C:`, UNC `\\`).
export function isAbsolutePath(p: string): boolean {
  if (!p) return false
  if (p.startsWith('/')) return true
  if (p.length >= 2 && /[A-Za-z]/.test(p[0] || '') && p[1] === ':') return true
  if (p.startsWith('\\\\')) return true
  return false
}

// Footer display: absolute paths verbatim, relative ones joined.
export function displayPathFor(cwd: string | undefined, filePath: string): string {
  if (cwd && !isAbsolutePath(filePath)) return `${cwd}/${filePath}`
  return filePath
}

export function fileNameOf(path: string): string {
  return path.split('/').pop() || path
}

// Only finite numbers > 0 are honored as a scroll target.
export function parseRequestedLine(param: unknown): number | null {
  const n =
    typeof param === 'string' ? parseInt(param, 10) : typeof param === 'number' ? param : NaN
  return Number.isFinite(n) && (n as number) > 0 ? (n as number) : null
}

// URL-safe file-path encoding: UTF-8 bytes → base64url (no padding). UTF-8 matters because raw
// `btoa` throws on non-latin1 paths (e.g. Cyrillic filenames); base64url matters because `+/=` are
// reserved in query strings.
export function encodeFilePath(path: string): string {
  const bytes = new TextEncoder().encode(path)
  let bin = ''
  bytes.forEach((b) => {
    bin += String.fromCharCode(b)
  })
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

// Inverse of encodeFilePath. Also accepts legacy raw-`btoa` links
// (with `+/=` and padding) so existing bookmarks keep working.
// Throws Error('invalid file link') when nothing decodes.
export function decodeFilePath(encoded: string): string {
  const cleaned = (encoded || '').trim()
  if (!cleaned) throw new Error('invalid file link')
  let b64 = cleaned.replace(/-/g, '+').replace(/_/g, '/')
  const rem = b64.length % 4
  if (rem === 1) throw new Error('invalid file link')
  if (rem > 0) b64 += '='.repeat(4 - rem)
  let bin: string
  try {
    bin = atob(b64)
  } catch {
    throw new Error('invalid file link')
  }
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0))
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch {
    // Legacy links were btoa() of a latin1 string — return it raw.
    return bin
  }
}

// New editor links carry the plain path (`?file=src/foo.ts`) so URLs stay readable and
// hand-editable. Links written before the readable migration carry base64/base64url instead.

// The two are told apart by a strict round-trip check: a legacy value decodes and re-encodes to
// itself, while a plain path either contains characters outside the base64 alphabet (`.` never
// appears in base64 output) or fails the re-encode comparison.

// A bare name like `TWFu` that happens to round-trip is misread as legacy — vanishingly rare, and
// the failure surfaces as an explicit read error, never a silent blank.
function isLegacyFileLink(value: string): boolean {
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) return false
  let decoded: string
  try {
    decoded = decodeFilePath(value)
  } catch {
    return false
  }
  const norm = (s: string): string => s.replace(/-/g, '+').replace(/_/g, '/').replace(/=+$/, '')
  return norm(encodeFilePath(decoded)) === norm(value)
}

// Resolve the `file` query value to a real path: legacy links decode,
// everything else passes through verbatim. Throws
// Error('invalid file link') on empty input, matching decodeFilePath.
export function resolveFileParam(raw: string): string {
  const value = (raw || '').trim()
  if (!value) throw new Error('invalid file link')
  if (isLegacyFileLink(value)) return decodeFilePath(value)
  return value
}

export type CodeEditorSessionDeps = {
  readFile: (cwd: string, path: string) => Promise<{ content: string }>
  syncUrl: (args: { path: string; cwd: string; line: number | null }) => void
}

export type RestoreArgs = {
  fileParam: string
  queryCwd: string
  fallbackCwd: string
  lineParam?: unknown
}

export function useCodeEditorSession(deps: CodeEditorSessionDeps) {
  const file = ref<FolderEntry | null>(null)
  const content = ref<string>('')
  const loading = ref(false)
  const error = ref<string | null>(null)
  const requestedLine = ref<number | null>(null)
  // The cwd the file was opened with, stored explicitly. Reads always
  // use this — never a recomputed sidebar value that may have changed
  // or resolved to '' since the file was opened.
  const cwd = ref<string>('')
  // Key of the last fully-resolved session (load or error). Guards
  // the open → router.replace → watcher → restore echo so one user
  // click costs exactly one fetch.
  const loadedKey = ref<string | null>(null)

  const sessionKey = (path: string, dir: string, line: number | null): string =>
    `${dir}\n${path}\n${line ?? ''}`

  function clear(): void {
    file.value = null
    content.value = ''
    error.value = null
    requestedLine.value = null
    cwd.value = ''
    loading.value = false
    loadedKey.value = null
  }

  async function openFile(opts: OpenInCodeEditorOptions): Promise<void> {
    const line = typeof opts.line === 'number' && opts.line > 0 ? opts.line : null
    if (!opts.filePath) {
      clear()
      error.value = 'No file path'
      return
    }
    if (!opts.cwd) {
      file.value = {
        path: opts.filePath,
        name: opts.fileName || fileNameOf(opts.filePath),
        is_directory: false,
        is_symlink: false,
      }
      content.value = ''
      requestedLine.value = line
      cwd.value = ''
      loading.value = false
      loadedKey.value = sessionKey(opts.filePath, '', line)
      error.value = 'No working directory'
      return
    }
    file.value = {
      path: opts.filePath,
      name: opts.fileName || fileNameOf(opts.filePath),
      is_directory: false,
      is_symlink: false,
    }
    requestedLine.value = line
    cwd.value = opts.cwd
    loading.value = true
    error.value = null
    content.value = ''
    try {
      const response = await deps.readFile(opts.cwd, opts.filePath)
      // Stale guard: another file was opened while fetching.
      if (file.value?.path !== opts.filePath) return
      content.value = response.content
      loadedKey.value = sessionKey(opts.filePath, opts.cwd, line)
      deps.syncUrl({ path: opts.filePath, cwd: opts.cwd, line })
    } catch {
      if (file.value?.path !== opts.filePath) return
      content.value = ''
      loadedKey.value = sessionKey(opts.filePath, opts.cwd, line)
      error.value = 'Failed to read file'
    } finally {
      if (file.value?.path === opts.filePath) loading.value = false
    }
  }

  // Rebuilds the session from the URL query (reload, Back/Forward,
  // shared link). Never leaves a silent blank: every failure sets
  // an explicit error state.
  async function restoreFromUrl(args: RestoreArgs): Promise<void> {
    const line = parseRequestedLine(args.lineParam)
    let path: string
    try {
      path = resolveFileParam(args.fileParam)
    } catch {
      clear()
      error.value = 'Invalid file link'
      return
    }
    const dir = args.queryCwd || args.fallbackCwd
    if (loadedKey.value === sessionKey(path, dir, line) && !loading.value) return
    if (!dir) {
      file.value = {
        path,
        name: fileNameOf(path),
        is_directory: false,
        is_symlink: false,
      }
      content.value = ''
      requestedLine.value = line
      cwd.value = ''
      loading.value = false
      loadedKey.value = sessionKey(path, '', line)
      error.value = 'No working directory'
      return
    }
    file.value = {
      path,
      name: fileNameOf(path),
      is_directory: false,
      is_symlink: false,
    }
    requestedLine.value = line
    cwd.value = dir
    loading.value = true
    error.value = null
    content.value = ''
    try {
      const response = await deps.readFile(dir, path)
      if (file.value?.path !== path) return
      content.value = response.content
      loadedKey.value = sessionKey(path, dir, line)
    } catch {
      if (file.value?.path !== path) return
      content.value = ''
      loadedKey.value = sessionKey(path, dir, line)
      error.value = 'Failed to read file'
    } finally {
      if (file.value?.path === path) loading.value = false
    }
  }

  return {
    file,
    content,
    loading,
    error,
    requestedLine,
    cwd,
    openFile,
    restoreFromUrl,
    clear,
  }
}

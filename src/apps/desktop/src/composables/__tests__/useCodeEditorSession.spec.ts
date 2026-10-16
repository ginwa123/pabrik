/** Tests for useCodeEditorSession.ts — the revamped open-file mechanism (task fix-open-file). */
import { describe, expect, it, vi } from 'vitest'

import {
  decodeFilePath,
  displayPathFor,
  encodeFilePath,
  fileNameOf,
  isAbsolutePath,
  parseRequestedLine,
  resolveFileParam,
  useCodeEditorSession,
} from '../useCodeEditorSession'

describe('isAbsolutePath', () => {
  it('detects POSIX, Windows drive and UNC absolutes', () => {
    expect(isAbsolutePath('/home/u/work/README.md')).toBe(true)
    expect(isAbsolutePath('C:/work/file.txt')).toBe(true)
    expect(isAbsolutePath('c:\\work\\file.txt')).toBe(true)
    expect(isAbsolutePath('\\\\server\\share')).toBe(true)
  })

  it('rejects relative paths and empties', () => {
    expect(isAbsolutePath('migration/README.md')).toBe(false)
    expect(isAbsolutePath('README.md')).toBe(false)
    expect(isAbsolutePath('')).toBe(false)
  })
})

describe('displayPathFor', () => {
  it('shows absolute filePath as-is (no cwd doubling)', () => {
    expect(displayPathFor('/home/u/work', '/home/u/work/migration/README.md')).toBe(
      '/home/u/work/migration/README.md',
    )
  })

  it('joins relative filePath with cwd', () => {
    expect(displayPathFor('/home/u/work', 'migration/README.md')).toBe(
      '/home/u/work/migration/README.md',
    )
  })

  it('falls back to filePath without cwd', () => {
    expect(displayPathFor('', '/a/b.md')).toBe('/a/b.md')
    expect(displayPathFor(undefined, 'a/b.md')).toBe('a/b.md')
  })
})

describe('file link encoding', () => {
  it('round-trips paths with spaces, plus signs and unicode', () => {
    for (const p of [
      '/home/u/work/migration/README.md',
      '/home/u/a b/c+d/e.md',
      '/home/u/файл/документ.md',
      'C:\\work\\my file.txt',
    ]) {
      expect(decodeFilePath(encodeFilePath(p))).toBe(p)
    }
  })

  it('emits URL-safe output (no +/=)', () => {
    // 0xfb 0xff bytes force +/ in standard base64.
    const out = encodeFilePath('/home/u/\u00fb\u00ff.md')
    expect(out).not.toMatch(/[+/=]/)
  })

  it('decodes legacy raw-btoa links', () => {
    const legacy = btoa('/home/u/work/migration/README.md')
    expect(decodeFilePath(legacy)).toBe('/home/u/work/migration/README.md')
  })

  it('throws on empty or corrupt links', () => {
    expect(() => decodeFilePath('')).toThrow('invalid file link')
    expect(() => decodeFilePath('!!!')).toThrow('invalid file link')
    expect(() => decodeFilePath('a')).toThrow('invalid file link')
  })
})

describe('resolveFileParam', () => {
  it('passes plain readable paths through verbatim', () => {
    expect(resolveFileParam('src/foo.ts')).toBe('src/foo.ts')
    expect(resolveFileParam('/w/migration/README.md')).toBe('/w/migration/README.md')
    expect(resolveFileParam('a b/c+d/e.md')).toBe('a b/c+d/e.md')
  })

  it('passes extensionless bare names through (no silent mis-decode)', () => {
    expect(resolveFileParam('Makefile')).toBe('Makefile')
    expect(resolveFileParam('README')).toBe('README')
    expect(resolveFileParam('!!!')).toBe('!!!')
  })

  it('decodes legacy base64url links', () => {
    const legacy = encodeFilePath('/w/migration/README.md')
    expect(resolveFileParam(legacy)).toBe('/w/migration/README.md')
  })

  it('decodes legacy raw-btoa links with padding', () => {
    const legacy = btoa('/w/migration/README.md')
    expect(resolveFileParam(legacy)).toBe('/w/migration/README.md')
  })

  it('throws on empty input', () => {
    expect(() => resolveFileParam('')).toThrow('invalid file link')
    expect(() => resolveFileParam('   ')).toThrow('invalid file link')
  })
})

describe('parseRequestedLine', () => {
  it('honors only finite numbers > 0', () => {
    expect(parseRequestedLine('17')).toBe(17)
    expect(parseRequestedLine(3)).toBe(3)
    expect(parseRequestedLine('0')).toBeNull()
    expect(parseRequestedLine('-2')).toBeNull()
    expect(parseRequestedLine('abc')).toBeNull()
    expect(parseRequestedLine(undefined)).toBeNull()
  })
})

describe('fileNameOf', () => {
  it('takes the last segment', () => {
    expect(fileNameOf('/a/b/README.md')).toBe('README.md')
    expect(fileNameOf('README.md')).toBe('README.md')
  })
})

function makeSession(overrides?: {
  readFile?: (cwd: string, path: string) => Promise<{ content: string }>
}) {
  const syncUrl = vi.fn()
  const readFile =
    overrides?.readFile ?? vi.fn(async (_cwd: string, _path: string) => ({ content: 'hello' }))
  const session = useCodeEditorSession({ readFile, syncUrl })
  return { session, syncUrl, readFile: readFile as ReturnType<typeof vi.fn> }
}

describe('openFile', () => {
  it('loads content, stores cwd and syncs a decodable URL', async () => {
    const { session, syncUrl, readFile } = makeSession()
    await session.openFile({ filePath: '/w/migration/README.md', cwd: '/w', line: 5 })

    expect(session.file.value?.path).toBe('/w/migration/README.md')
    expect(session.file.value?.name).toBe('README.md')
    expect(session.content.value).toBe('hello')
    expect(session.loading.value).toBe(false)
    expect(session.error.value).toBeNull()
    expect(session.cwd.value).toBe('/w')
    expect(session.requestedLine.value).toBe(5)
    expect(readFile).toHaveBeenCalledWith('/w', '/w/migration/README.md')
    expect(syncUrl).toHaveBeenCalledTimes(1)
    const arg = syncUrl.mock.calls[0]?.[0] as { path: string; cwd: string; line: number | null }
    expect(arg).toMatchObject({ path: '/w/migration/README.md', cwd: '/w', line: 5 })
    expect(decodeFilePath(encodeFilePath(arg.path))).toBe('/w/migration/README.md')
  })

  it('sets a visible error instead of silently returning without cwd', async () => {
    const { session, readFile, syncUrl } = makeSession()
    await session.openFile({ filePath: '/w/a.md', cwd: '' })

    expect(readFile).not.toHaveBeenCalled()
    expect(syncUrl).not.toHaveBeenCalled()
    expect(session.file.value?.path).toBe('/w/a.md')
    expect(session.error.value).toBe('No working directory')
    expect(session.loading.value).toBe(false)
  })

  it('surfaces read failures as an error state', async () => {
    const { session } = makeSession({
      readFile: async () => {
        throw new Error('boom')
      },
    })
    await session.openFile({ filePath: '/w/a.md', cwd: '/w' })

    expect(session.content.value).toBe('')
    expect(session.error.value).toBe('Failed to read file')
    expect(session.loading.value).toBe(false)
  })
})

describe('restoreFromUrl', () => {
  it('restores the session from a plain readable link', async () => {
    const { session, readFile } = makeSession()
    await session.restoreFromUrl({
      fileParam: 'migration/README.md',
      queryCwd: '/w',
      fallbackCwd: '',
    })

    expect(session.file.value?.path).toBe('migration/README.md')
    expect(session.content.value).toBe('hello')
    expect(session.error.value).toBeNull()
    expect(readFile).toHaveBeenCalledWith('/w', 'migration/README.md')
  })

  it('restores the session from a legacy encoded link', async () => {
    const { session, readFile } = makeSession()
    const encoded = encodeFilePath('/w/migration/README.md')
    await session.restoreFromUrl({ fileParam: encoded, queryCwd: '/w', fallbackCwd: '' })

    expect(session.file.value?.path).toBe('/w/migration/README.md')
    expect(session.content.value).toBe('hello')
    expect(session.error.value).toBeNull()
    expect(readFile).toHaveBeenCalledWith('/w', '/w/migration/README.md')
  })

  it('skips the refetch when the URL echoes the open session', async () => {
    const { session, readFile } = makeSession()
    await session.openFile({ filePath: '/w/a.md', cwd: '/w' })
    expect(readFile).toHaveBeenCalledTimes(1)

    const encoded = encodeFilePath('/w/a.md')
    await session.restoreFromUrl({ fileParam: encoded, queryCwd: '/w', fallbackCwd: '/w' })
    expect(readFile).toHaveBeenCalledTimes(1)
  })

  it('prefers the explicit query cwd over the sidebar fallback', async () => {
    const { session, readFile } = makeSession()
    const encoded = encodeFilePath('/w/a.md')
    await session.restoreFromUrl({
      fileParam: encoded,
      queryCwd: '/w-explicit',
      fallbackCwd: '/w-fb',
    })

    expect(session.cwd.value).toBe('/w-explicit')
    expect(readFile).toHaveBeenCalledWith('/w-explicit', '/w/a.md')
  })

  it('sets an explicit error for empty links', async () => {
    const { session, readFile } = makeSession()
    await session.restoreFromUrl({ fileParam: '', queryCwd: '/w', fallbackCwd: '' })

    expect(readFile).not.toHaveBeenCalled()
    expect(session.file.value).toBeNull()
    expect(session.error.value).toBe('Invalid file link')
  })

  it('treats undecodable values as plain names and attempts the read', async () => {
    const { session, readFile } = makeSession()
    await session.restoreFromUrl({ fileParam: '!!!', queryCwd: '/w', fallbackCwd: '' })

    expect(readFile).toHaveBeenCalledWith('/w', '!!!')
    expect(session.file.value?.path).toBe('!!!')
  })

  it('keeps the header but errors visibly when no cwd resolves', async () => {
    const { session, readFile } = makeSession()
    const encoded = encodeFilePath('/w/a.md')
    await session.restoreFromUrl({ fileParam: encoded, queryCwd: '', fallbackCwd: '' })

    expect(readFile).not.toHaveBeenCalled()
    expect(session.file.value?.path).toBe('/w/a.md')
    expect(session.error.value).toBe('No working directory')
  })
})

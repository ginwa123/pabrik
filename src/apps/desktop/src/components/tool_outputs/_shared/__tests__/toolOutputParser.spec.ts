/** Tests for toolOutputParser.ts — typed JSON parsers used by tool-output components. Each parser
 * takes the envelope `data` payload as an object and handles missing fields gracefully. */
/** These tests verify the type contracts and edge cases (empty content, missing required fields,
 * multiline values, special chars, both success/error branches). */
import { describe, expect, it } from 'vitest'
import {
  extractBool,
  extractInt,
  extractTag,
  parseAddSkill,
  parseBash,
  parseCommand,
  parseEditSkill,
  parseMcp,
  parsePwsh,
  parseShell,
  parseSearchSkills,
  parseMetadata,
  parseReadFile,
  parseRemoveFile,
  parseRemoveSkill,
  parseSearch,
  parseSetGitWorktree,
  parseSetPullRequest,
  parseTextReplace,
  parseKanbanList,
  parseKanbanMove,
  parseGenerateImage,
  parseListDirectory,
  parseWriteFile,
  parsePresentFiles,
  isPreviewableImage,
  basenameOfPath,
  formatBytes,
} from '../toolOutputParser'

describe('extractTag', () => {
  it('returns inner text for single-line tags', () => {
    expect(extractTag('<path>/foo/bar</path>', 'path')).toBe('/foo/bar')
  })
  it('returns inner text for multiline tags (default)', () => {
    expect(extractTag('<content>\nfoo\nbar\n</content>', 'content')).toBe('\nfoo\nbar\n')
  })
  it('returns null for missing tag', () => {
    expect(extractTag('<path>/x</path>', 'other')).toBeNull()
  })
  it('returns null for unclosed tag', () => {
    expect(extractTag('<path>/x', 'path')).toBeNull()
  })
  it('handles content with HTML-like chars inside the tag', () => {
    expect(extractTag('<content>if (a < b && c > d) { x = 1 }</content>', 'content')).toBe(
      'if (a < b && c > d) { x = 1 }',
    )
  })
  it('decodes XML entities in inner text (&lt;, &gt;, &quot;, &apos;, &amp;)', () => {
    // The backend's `toXmlSuccess` / `xmlError` helpers escape these 5 characters on serialization.

    // Without un-escaping, downstream consumers (Vue templates, code-block renderers) would display
    // `&quot;` literally instead of `"` when the underlying text contained those characters (e.g. a
    // quote inside a source-code diff).

    // This test pins the un-escape contract so the `&quot;`-instead-of-`"` rendering bug doesn't
    // regress.
    expect(
      extractTag('<before>const x = &quot;hello &amp; world &lt;3&quot;;</before>', 'before'),
    ).toBe('const x = "hello & world <3";')
    expect(extractTag('<a>&lt;tag&gt;</a>', 'a')).toBe('<tag>')
    expect(extractTag('<a>it&apos;s fine</a>', 'a')).toBe("it's fine")
  })
  it('decodes &amp; LAST to avoid double-decoding (e.g. &amp;quot; → &quot; not ")', () => {
    // `&amp;quot;` is a 6-byte sequence meaning "the literal entity &quot;". If we decoded `&amp;`
    // first, we'd incorrectly produce `"` (because `&amp;quot;` → `&quot;` → `"` after both
    // passes).

    // The correct decode is: `&amp;quot;` → `&quot;` (the literal 6 chars representing the entity).
    // Order of regex passes matters.
    expect(extractTag('<a>&amp;quot;</a>', 'a')).toBe('&quot;')
    expect(extractTag('<a>&amp;amp;</a>', 'a')).toBe('&amp;')
  })
})

describe('extractBool', () => {
  it('returns true for <true>', () => {
    expect(extractBool('<x>true</x>', 'x')).toBe(true)
  })
  it('returns false for <false>', () => {
    expect(extractBool('<x>false</x>', 'x')).toBe(false)
  })
  it('returns defaultValue when tag missing', () => {
    expect(extractBool('<other>1</other>', 'x', false)).toBe(false)
    expect(extractBool('<other>1</other>', 'x', true)).toBe(true)
  })
  it('handles whitespace inside the tag value', () => {
    expect(extractBool('<x>  true  </x>', 'x')).toBe(true)
  })
})

describe('extractInt', () => {
  it('parses a valid integer', () => {
    expect(extractInt('<n>42</n>', 'n')).toBe(42)
  })
  it('returns null on missing tag', () => {
    expect(extractInt('<n>42</n>', 'other')).toBeNull()
  })
  it('returns null on non-numeric value', () => {
    expect(extractInt('<n>foo</n>', 'n')).toBeNull()
  })
  it('returns null on empty tag', () => {
    expect(extractInt('<n></n>', 'n')).toBeNull()
  })
  it('parses 0', () => {
    expect(extractInt('<n>0</n>', 'n')).toBe(0)
  })
})

describe('parseTextReplace', () => {
  it('parses a successful response with diff data', () => {
    const r = parseTextReplace({
      path: '/foo',
      before: 'old',
      after: 'new',
      lines_changed: 3,
      error: null,
    })
    expect(r.path).toBe('/foo')
    expect(r.before).toBe('old')
    expect(r.after).toBe('new')
    expect(r.linesChanged).toBe(3)
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
  it('handles error response with null success', () => {
    const r = parseTextReplace({ path: '', error: 'not found' })
    expect(r.success).toBe(false)
    expect(r.error).toBe('not found')
    expect(r.path).toBe('')
    expect(r.linesChanged).toBe(0)
  })
  it('handles missing error field (defaults to success)', () => {
    const r = parseTextReplace({ path: '/foo' })
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
  it('extracts the unified diff when present', () => {
    const unified = '--- a/x\n+++ b/x\n@@ -1,1 +1,1 @@\n-old\n+new'
    const r = parseTextReplace({ path: '/x', unified })
    expect(r.unified).toBe(unified)
  })
  it('accepts the payload as a JSON string', () => {
    const r = parseTextReplace(JSON.stringify({ path: '/x', before: 'a', after: 'b' }))
    expect(r.path).toBe('/x')
    expect(r.before).toBe('a')
  })
})

describe('parseReadFile', () => {
  it('parses success with content and pagination', () => {
    const r = parseReadFile({
      path: '/x',
      content: 'line1\nline2',
      total_lines: 10,
      start_line: 1,
      end_line: 2,
    })
    expect(r.path).toBe('/x')
    expect(r.content).toBe('line1\nline2')
    expect(r.totalLines).toBe(10)
    expect(r.startLine).toBe(1)
    expect(r.endLine).toBe(2)
    expect(r.success).toBe(true)
  })
  it('returns null numeric fields when missing', () => {
    const r = parseReadFile({ path: '/x' })
    expect(r.totalLines).toBeNull()
  })
  it('returns error when not success', () => {
    const r = parseReadFile({ path: '/x', success: false, error: 'permission denied' })
    expect(r.error).toBe('permission denied')
    expect(r.success).toBe(false)
  })
  it('accepts the payload as a JSON string', () => {
    const r = parseReadFile(JSON.stringify({ path: '/x', content: 'hi' }))
    expect(r.path).toBe('/x')
    expect(r.content).toBe('hi')
  })
})

describe('parseWriteFile', () => {
  it('parses file_write', () => {
    const r = parseWriteFile({ file_write: '/x/y', error: null })
    expect(r.path).toBe('/x/y')
    expect(r.success).toBe(true)
  })
  it('parses error', () => {
    const r = parseWriteFile({ file_write: '', error: 'disk full' })
    expect(r.path).toBe('')
    expect(r.error).toBe('disk full')
  })
})

describe('parseRemoveFile', () => {
  it('parses deleted=true', () => {
    const r = parseRemoveFile({ path: '/x', deleted: true, error: null })
    expect(r.deleted).toBe(true)
    expect(r.success).toBe(true)
  })
  it('parses recursive flag', () => {
    const r = parseRemoveFile({ path: '/x', deleted: true, recursive: true })
    expect(r.recursive).toBe(true)
  })
  it('handles failure', () => {
    const r = parseRemoveFile({ path: '', error: 'not found' })
    expect(r.deleted).toBe(false)
    expect(r.error).toBe('not found')
  })
})

describe('parseEditSkill', () => {
  it('parses edited=true and the name', () => {
    const r = parseEditSkill({ skill_name: 'auth', name: 'auth', updated: true, edited: true })
    expect(r.skillName).toBe('auth')
    expect(r.edited).toBe(true)
    expect(r.success).toBe(true)
  })
  it('falls back to `name` when skill_name is absent', () => {
    const r = parseEditSkill({ name: 'x', edited: true })
    expect(r.skillName).toBe('x')
  })
  it('falls back to `name` when skill_name is empty', () => {
    // `''` is neither null nor undefined, so a `??` chain alone would let
    // the blank name win and render an unlabelled card.
    const r = parseEditSkill({ skill_name: '', name: 'x', edited: true })
    expect(r.skillName).toBe('x')
  })
  it('ignores a path left over on an older payload', () => {
    const r = parseEditSkill({ skill_name: 'auth', edited: true, path: '/skills/auth.md' })
    expect(r.skillName).toBe('auth')
    expect('path' in r).toBe(false)
  })
})

describe('parseAddSkill', () => {
  it('parses created=true', () => {
    const r = parseAddSkill({ skill_name: 'foo', name: 'foo', created: true })
    expect(r.created).toBe(true)
    expect(r.skillName).toBe('foo')
  })
  it('surfaces the error and drops success', () => {
    const r = parseAddSkill({ skill_name: 'foo', created: false, error: 'name already exists' })
    expect(r.success).toBe(false)
    expect(r.error).toBe('name already exists')
    expect(r.created).toBe(false)
  })
  it('never exposes a path', () => {
    const r = parseAddSkill({ name: 'foo', created: true, path: '/x' })
    expect('path' in r).toBe(false)
  })
})

describe('parseRemoveSkill', () => {
  it('parses skill_name and removed', () => {
    const r = parseRemoveSkill({ skill_name: 'foo', removed: true })
    expect(r.skillName).toBe('foo')
    expect(r.removed).toBe(true)
  })
  it('never exposes a path', () => {
    const r = parseRemoveSkill({ skill_name: 'foo', removed: true, path: '/x' })
    expect('path' in r).toBe(false)
  })
})

describe('parseSetGitWorktree', () => {
  it('parses created=true with path and branch', () => {
    const r = parseSetGitWorktree({
      created: true,
      path: '/.worktrees/auth',
      branch: 'worktree/auth',
    })
    expect(r.created).toBe(true)
    expect(r.path).toBe('/.worktrees/auth')
    expect(r.branch).toBe('worktree/auth')
  })
  it('parses cleared=true', () => {
    const r = parseSetGitWorktree({ cleared: true })
    expect(r.cleared).toBe(true)
    expect(r.success).toBe(true)
  })
  it('returns success=false on error', () => {
    const r = parseSetGitWorktree({ error: 'missing path' })
    expect(r.success).toBe(false)
  })
})

describe('parseBash', () => {
  it('parses a successful command with stdout', () => {
    const r = parseBash({
      command: 'ls',
      stdout: 'file1\nfile2',
      exit_code: 0,
      stdout_lines: 2,
    })
    expect(r.command).toBe('ls')
    expect(r.stdout).toBe('file1\nfile2')
    expect(r.exitCode).toBe(0)
    expect(r.stdoutLines).toBe(2)
    expect(r.timedOut).toBe(false)
  })
  it('parses timeout flag', () => {
    const r = parseBash({ command: 'sleep 1', timeout: true })
    expect(r.timedOut).toBe(true)
  })
  it('parses exit_code=null when not present', () => {
    const r = parseBash({ command: 'x' })
    expect(r.exitCode).toBeNull()
  })
})

describe('parseSearch', () => {
  it('parses file results with matches', () => {
    const r = parseSearch({
      pattern: 'hello',
      path: '/foo',
      files: [
        {
          path: '/foo/bar.ts',
          total: 42,
          count: 3,
          matches: [
            { line: 10, text: 'hello' },
            { line: 20, text: 'world' },
          ],
        },
      ],
      warning: null,
    })
    expect(r.fileResults).toHaveLength(1)
    const fr = r.fileResults[0]!
    expect(fr.path).toBe('/foo/bar.ts')
    expect(fr.total).toBe(42)
    expect(fr.count).toBe(3)
    expect(fr.matches).toEqual([
      { lineNumber: 10, snippet: 'hello' },
      { lineNumber: 20, snippet: 'world' },
    ])
  })
  it('renders <>& snippet text verbatim (no entity layer in JSON)', () => {
    const r = parseSearch({
      files: [{ path: '/x', total: 1, count: 1, matches: [{ line: 1, text: 'if a < b' }] }],
    })
    expect(r.fileResults[0]?.matches[0]?.snippet).toBe('if a < b')
  })
  it('returns empty results for a payload with no files', () => {
    const r = parseSearch({ pattern: 'x', path: '/y', files: [], warning: 'no matches' })
    expect(r.success).toBe(true)
    expect(r.warning).toBe('no matches')
    expect(r.fileResults).toEqual([])
  })
  it('reads the truncation summary fields', () => {
    const r = parseSearch({
      returned: 2,
      total: 40,
      truncated: true,
      output_truncated: true,
      truncated_hint: 'max_output truncated the raw output',
      files: [],
    })
    expect(r.returned).toBe(2)
    expect(r.total).toBe(40)
    expect(r.truncated).toBe(true)
    expect(r.outputTruncated).toBe(true)
    expect(r.truncatedHint).toContain('max_output')
  })
  it('keeps outputTruncated false for legacy search payloads', () => {
    const r = parseSearch({ returned: 1, total: 1, truncated: false, files: [] })
    expect(r.outputTruncated).toBe(false)
    expect(r.truncatedHint).toBeNull()
  })
})

describe('parseSearchSkills', () => {
  it('parses flat skills[] rows of name + description and nothing else', () => {
    const r = parseSearchSkills({
      query: 'auth',
      pattern_mode: 'regex',
      count: 2,
      total: 2,
      offset: 0,
      limit: 20,
      skills: [
        { name: 'auth', description: 'handles auth' },
        { name: 'auth-local', description: '' },
      ],
      truncated: false,
      next_offset: null,
      hint: 'h',
    })
    expect(r.query).toBe('auth')
    expect(r.patternMode).toBe('regex')
    expect(r.skills).toHaveLength(2)
    expect(r.skills[0]).toEqual({ name: 'auth', description: 'handles auth' })
    expect(r.skills[1]).toEqual({ name: 'auth-local', description: '' })
    // No tier and no location survive: a row is a name and a description.
    expect('scope' in r).toBe(false)
    expect('scope' in (r.skills[0] as object)).toBe(false)
    expect('path' in (r.skills[0] as object)).toBe(false)
  })
  it('reads rows that still carry the old scope / path keys', () => {
    // A transcript recorded before the table refactor must not render as
    // blank rows, so the extra keys are ignored rather than demanded.
    const r = parseSearchSkills({
      skills: [{ name: 'auth', description: 'd', scope: 'global', path: '/g/SKILL.MD' }],
    })
    expect(r.skills).toEqual([{ name: 'auth', description: 'd' }])
  })
  it('keeps the paging fields of a truncated page', () => {
    const r = parseSearchSkills({
      query: 'a',
      pattern_mode: 'all',
      pattern_warning: null,
      count: 2,
      total: 7,
      offset: 4,
      limit: 2,
      skills: [
        { name: 'a1', description: '' },
        { name: 'a2', description: '' },
      ],
      truncated: true,
      next_offset: 6,
      hint: 'call again with offset=6',
    })
    expect(r.count).toBe(2)
    expect(r.total).toBe(7)
    expect(r.offset).toBe(4)
    expect(r.limit).toBe(2)
    expect(r.truncated).toBe(true)
    expect(r.nextOffset).toBe(6)
    expect(r.hint).toBe('call again with offset=6')
  })
  it('surfaces a pattern_warning verbatim', () => {
    const r = parseSearchSkills({
      query: 'foo(',
      pattern_mode: 'literal_fallback',
      pattern_warning: 'unbalanced ( — matched as a literal',
      skills: [],
    })
    expect(r.patternWarning).toBe('unbalanced ( — matched as a literal')
    expect(r.patternMode).toBe('literal_fallback')
  })
  it('drops rows with no name and tolerates a non-array skills field', () => {
    const r = parseSearchSkills({ skills: [{ description: 'nameless' }, 'nope', null] })
    expect(r.skills).toHaveLength(0)
    const bad = parseSearchSkills({ skills: 'not-an-array' })
    expect(bad.skills).toHaveLength(0)
  })
  it('yields zero rows and no throw for empty / missing data', () => {
    const empty = parseSearchSkills({})
    expect(empty.skills).toHaveLength(0)
    expect(empty.count).toBe(0)
    expect(empty.total).toBe(0)
    expect(empty.query).toBe('')
    expect(empty.truncated).toBe(false)
    expect(empty.patternWarning).toBeNull()
    expect(empty.offset).toBeNull()
    expect(empty.limit).toBeNull()
    expect(empty.nextOffset).toBeNull()
    expect(empty.hint).toBeNull()

    expect(parseSearchSkills(null).skills).toHaveLength(0)
    expect(parseSearchSkills(undefined).skills).toHaveLength(0)
    expect(parseSearchSkills('not json').skills).toHaveLength(0)
    // count / total fall back to the rendered row count.
    const rowsOnly = parseSearchSkills({
      skills: [{ name: 'x', description: 'd' }],
    })
    expect(rowsOnly.count).toBe(1)
    expect(rowsOnly.total).toBe(1)
  })
  it('unwraps a full tool envelope to its data payload', () => {
    const r = parseSearchSkills({
      tool: 'search_skills',
      success: true,
      data: {
        query: 'db',
        skills: [{ name: 'db', description: 'db stuff' }],
      },
    })
    expect(r.query).toBe('db')
    expect(r.skills).toHaveLength(1)
  })
})
describe('parseKanbanList', () => {
  it('parses workspace/item, columns and tasks', () => {
    const r = parseKanbanList({
      workspace_id: 'ws1',
      item_id: 'item1',
      columns: [
        { id: 'c1', name: 'Todo', position: 0, task_count: 5 },
        { id: 'c2', name: 'Done', position: 1, task_count: 3 },
      ],
      tasks: [{ id: 't1', name: 'Fix it', column_id: 'c1', column_name: 'Todo', position: 0 }],
      total_count: 1,
      limit: 50,
      offset: 0,
      has_more: false,
      hint: null,
    })
    expect(r.workspaceId).toBe('ws1')
    expect(r.itemId).toBe('item1')
    expect(r.columns).toHaveLength(2)
    expect(r.columns[0]).toMatchObject({ id: 'c1', name: 'Todo', taskCount: 5 })
    expect(r.tasks).toHaveLength(1)
    expect(r.tasks[0]).toMatchObject({ id: 't1', columnId: 'c1' })
    expect(r.totalCount).toBe(1)
  })
  it('returns success=false on error', () => {
    const r = parseKanbanList({ error: 'not found' })
    expect(r.success).toBe(false)
    expect(r.columns).toEqual([])
  })
})

describe('parseKanbanMove', () => {
  it('parses move details', () => {
    const r = parseKanbanMove({
      success: true,
      task_id: 't1',
      task_name: 'Fix it',
      column_id: 'c2',
      column_name: 'Done',
      position: 0,
    })
    expect(r.success).toBe(true)
    expect(r.taskId).toBe('t1')
    expect(r.taskName).toBe('Fix it')
    expect(r.columnId).toBe('c2')
    expect(r.columnName).toBe('Done')
  })
  it('returns success=false on error', () => {
    const r = parseKanbanMove({ success: false, error: 'TaskNotFound' })
    expect(r.success).toBe(false)
    expect(r.error).toBe('TaskNotFound')
  })
})

describe('parseGenerateImage', () => {
  it('parses a single-image success envelope', () => {
    const r = parseGenerateImage({
      status: 'generated',
      count: 1,
      model: 'dall-e-3',
      size: '1024x1024',
      images: [{ index: 0, path: '/cwd/img_123.png', bytes: 12345, mime: 'image/png' }],
      revised_prompt: 'A vibrant watercolor of a cat',
    })
    expect(r.error).toBeNull()
    expect(r.status).toBe('generated')
    expect(r.count).toBe(1)
    expect(r.model).toBe('dall-e-3')
    expect(r.size).toBe('1024x1024')
    expect(r.images).toHaveLength(1)
    expect(r.images[0]).toMatchObject({
      index: 0,
      path: '/cwd/img_123.png',
      bytes: 12345,
      mime: 'image/png',
    })
    expect(r.revisedPrompt).toBe('A vibrant watercolor of a cat')
  })
  it('parses a multi-image (n>1, DALL-E 2) success envelope', () => {
    const r = parseGenerateImage({
      status: 'generated',
      count: 2,
      model: 'dall-e-2',
      size: '512x512',
      images: [
        { index: 0, path: '/cwd/img_a.png', bytes: 100, mime: 'image/png' },
        { index: 1, path: '/cwd/img_b.png', bytes: 200, mime: 'image/png' },
      ],
    })
    expect(r.error).toBeNull()
    expect(r.count).toBe(2)
    expect(r.images).toHaveLength(2)
    expect(r.images[0]?.path).toBe('/cwd/img_a.png')
    expect(r.images[1]?.path).toBe('/cwd/img_b.png')
    expect(r.revisedPrompt).toBeNull()
  })
  it('returns the error message and null fields on error', () => {
    const r = parseGenerateImage({
      error: "HTTP 400: size '512x512' is not valid for model 'dall-e-3'.",
    })
    expect(r.error).toBe("HTTP 400: size '512x512' is not valid for model 'dall-e-3'.")
    expect(r.status).toBeNull()
    expect(r.images).toEqual([])
    expect(r.count).toBeNull()
  })
  it('handles empty content gracefully', () => {
    const r = parseGenerateImage({})
    expect(r.error).toBeNull()
    expect(r.status).toBeNull()
    expect(r.images).toEqual([])
  })
})

describe('parseMetadata', () => {
  it('flattens a metadata object into key/value pairs', () => {
    const r = parseMetadata({ metadata: { session_id: 's1', model: 'm1', count: 3 } })
    expect(r.session_id).toBe('s1')
    expect(r.model).toBe('m1')
    expect(r.count).toBe('3')
  })
  it('returns empty object when no metadata', () => {
    expect(parseMetadata({})).toEqual({})
  })
})

// 2026-08-14 — list_directory tool output (companion to ReadFile/Search/Glob).
// Wire shape (from src/modules/agent/tools/list_directory.zig):
//
//   {"path":"/foo/bar","count":3,"entries":[
//     {"name":"src","path":"/foo/bar/src","is_directory":true,"is_symlink":false},
//     {"name":"main.zig","path":"/foo/bar/main.zig","is_directory":false,"is_symlink":false}
//   ]}
describe('parseListDirectory', () => {
  it('parses a success envelope with directories + files', () => {
    const r = parseListDirectory({
      path: '/proj',
      count: 3,
      entries: [
        { name: 'src', path: '/proj/src', is_directory: true, is_symlink: false },
        { name: 'README.md', path: '/proj/README.md', is_directory: false, is_symlink: false },
        { name: 'main.zig', path: '/proj/main.zig', is_directory: false, is_symlink: false },
      ],
    })
    expect(r.path).toBe('/proj')
    expect(r.count).toBe(3)
    expect(r.entries).toHaveLength(3)
    expect(r.entries[0]).toMatchObject({
      name: 'src',
      path: '/proj/src',
      isDirectory: true,
      isSymlink: false,
    })
    expect(r.entries[1]).toMatchObject({
      name: 'README.md',
      path: '/proj/README.md',
      isDirectory: false,
      isSymlink: false,
    })
    expect(r.entries[2]?.name).toBe('main.zig')
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })

  it('parses an empty directory listing (count=0)', () => {
    const r = parseListDirectory({ path: '/empty', count: 0, entries: [] })
    expect(r.path).toBe('/empty')
    expect(r.count).toBe(0)
    expect(r.entries).toEqual([])
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })

  it('parses a directory-only listing', () => {
    const r = parseListDirectory({
      path: '/only-dirs',
      count: 2,
      entries: [
        { name: 'a', path: '/only-dirs/a', is_directory: true, is_symlink: false },
        { name: 'b', path: '/only-dirs/b', is_directory: true, is_symlink: false },
      ],
    })
    expect(r.count).toBe(2)
    expect(r.entries.every((e) => e.isDirectory)).toBe(true)
  })

  it('flags symlinks via is_symlink=true', () => {
    const r = parseListDirectory({
      path: '/proj',
      count: 1,
      entries: [
        { name: 'link.txt', path: '/proj/link.txt', is_directory: false, is_symlink: true },
      ],
    })
    expect(r.entries[0]?.isSymlink).toBe(true)
    expect(r.entries[0]?.isDirectory).toBe(false)
  })

  it('returns success=false + error message on error envelope', () => {
    // normalizeToolContent unwraps the full envelope; the parser sees the
    // inner data object carrying the error.
    const r = parseListDirectory({ error: 'list_directory failed: PathNotFound' })
    expect(r.success).toBe(false)
    expect(r.error).toBe('list_directory failed: PathNotFound')
    expect(r.entries).toEqual([])
  })

  it('handles empty content gracefully (no envelope at all)', () => {
    const r = parseListDirectory({})
    expect(r.path).toBe('')
    expect(r.count).toBe(0)
    expect(r.entries).toEqual([])
    expect(r.success).toBe(true)
    expect(r.error).toBeNull()
  })
})

// 2026-08-14 pwsh-tool: parsePwsh mirrors parseBash (same JSON payload per
// D2 + D10). Wire-contract parity test.
describe('parsePwsh', () => {
  const payload = {
    command: 'Get-ChildItem',
    stdout: 'file1\nfile2',
    stderr: '',
    exit_code: 0,
    truncated: false,
    timeout: false,
    stdout_lines: 2,
    stderr_lines: 0,
  }

  it('parses a PowerShell command result with the same shape as parseBash', () => {
    const r = parsePwsh(payload)
    expect(r.command).toBe('Get-ChildItem')
    expect(r.stdout).toBe('file1\nfile2')
    expect(r.exitCode).toBe(0)
    expect(r.truncated).toBe(false)
    expect(r.timedOut).toBe(false)
    expect(r.stdoutLines).toBe(2)
    expect(r.stderrLines).toBe(0)
  })

  it('returns the same ParsedBash shape as parseBash for the same input', () => {
    // Lock-down test: pwsh + bash share the wire payload. If a future
    // refactor diverges them, this assertion fails closed.
    expect(parsePwsh(payload)).toEqual(parseBash(payload))
  })
})

// unify-command Phase C: `command` (unified shell) reuses the identical
// 8-field payload. `parseBash` / `parsePwsh` specs above are untouched;
// these cases only lock the new alias + dispatcher branch.
describe('parseCommand', () => {
  const payload = {
    command: 'ls -la',
    stdout: 'file1\nfile2',
    stderr: '',
    exit_code: 0,
    truncated: false,
    timeout: false,
    stdout_lines: 2,
    stderr_lines: 0,
  }

  it('parses a unified command result with the same shape as parseBash', () => {
    const r = parseCommand(payload)
    expect(r.command).toBe('ls -la')
    expect(r.stdout).toBe('file1\nfile2')
    expect(r.exitCode).toBe(0)
    expect(r.stdoutLines).toBe(2)
    expect(r.timedOut).toBe(false)
  })

  it('returns the same ParsedBash shape as parseBash for the same input', () => {
    expect(parseCommand(payload)).toEqual(parseBash(payload))
  })

  it("parseShell('command') equals parseBash for the same input", () => {
    expect(parseShell('command', payload)).toEqual(parseBash(payload))
  })

  it('parseShell still dispatches legacy names (bash/pwsh/run_command)', () => {
    expect(parseShell('bash', payload)).toEqual(parseBash(payload))
    expect(parseShell('pwsh', payload)).toEqual(parseBash(payload))
    expect(parseShell('run_command', payload)).toEqual(parseBash(payload))
  })
})

describe('parseMcp', () => {
  it('splits mcp_<server>_<tool> into server + subTool', () => {
    const r = parseMcp('mcp_graphify_graph_stats', 'Nodes: 14885')
    expect(r.server).toBe('graphify')
    expect(r.subTool).toBe('graph_stats')
    expect(r.output).toBe('Nodes: 14885')
    expect(r.success).toBe(true)
  })

  it('keeps multi-underscore sub-tools intact (mcp_db_query_v2)', () => {
    const r = parseMcp('mcp_db_query_v2', 'ok')
    expect(r.server).toBe('db')
    expect(r.subTool).toBe('query_v2')
  })

  it('pretty-prints JSON output', () => {
    const r = parseMcp('mcp_db_query', '{"a":1,"b":[1,2]}')
    expect(r.isJson).toBe(true)
    expect(r.prettyOutput).toBe(JSON.stringify({ a: 1, b: [1, 2] }, null, 2))
  })

  it('unwraps the error envelope (backend failure path)', () => {
    const envelope = {
      tool: 'mcp_graphify_graph_stats',
      parameters: {},
      success: false,
      error: 'connection refused',
      data: null,
    }
    const r = parseMcp('mcp_graphify_graph_stats', envelope)
    expect(r.success).toBe(false)
    expect(r.error).toBe('connection refused')
    expect(r.output).toBe('')
  })

  it('unwraps the success data envelope (placeholder shape)', () => {
    const envelope = {
      tool: 'mcp_db_query',
      parameters: { q: '1' },
      success: true,
      error: null,
      data: 'row1',
    }
    const r = parseMcp('mcp_db_query', envelope)
    expect(r.success).toBe(true)
    expect(r.output).toBe('row1')
  })
})
describe('parsePresentFiles', () => {
  it('parses a txt + jpg success envelope', () => {
    const r = parsePresentFiles({
      status: 'presented',
      count: 2,
      files: [
        { path: '/tmp/notes.txt', bytes: 11, mime: 'text/plain; charset=utf-8', label: 'notes' },
        { path: '/tmp/photo.jpg', bytes: 48211, mime: 'image/jpeg', label: 'photo.jpg' },
      ],
    })
    expect(r.error).toBeNull()
    expect(r.status).toBe('presented')
    expect(r.count).toBe(2)
    expect(r.files).toHaveLength(2)
    expect(r.files[0]).toMatchObject({
      path: '/tmp/notes.txt',
      bytes: 11,
      mime: 'text/plain; charset=utf-8',
      label: 'notes',
    })
    expect(r.files[1]).toMatchObject({
      path: '/tmp/photo.jpg',
      bytes: 48211,
      mime: 'image/jpeg',
      label: 'photo.jpg',
    })
  })
  it('returns the error message and empty files on error', () => {
    const r = parsePresentFiles({
      status: null,
      count: 0,
      files: [],
      error: 'present_files: file not found (or is a directory): "/tmp/nope.txt".',
    })
    expect(r.error).toContain('file not found')
    expect(r.status).toBeNull()
    expect(r.files).toEqual([])
    expect(r.count).toBeNull()
  })
  it('handles empty content gracefully', () => {
    const r = parsePresentFiles({})
    expect(r.error).toBeNull()
    expect(r.status).toBeNull()
    expect(r.files).toEqual([])
  })
  it('keeps special characters raw (JSON needs no escaping)', () => {
    const r = parsePresentFiles({
      status: 'presented',
      count: 1,
      files: [{ path: '/tmp/a&b.txt', bytes: 3, mime: 'text/plain; charset=utf-8', label: 'a&b' }],
    })
    expect(r.files[0]?.path).toBe('/tmp/a&b.txt')
    expect(r.files[0]?.label).toBe('a&b')
  })
})

describe('present files helpers', () => {
  it('isPreviewableImage matches image/* case-insensitively', () => {
    expect(isPreviewableImage('image/jpeg')).toBe(true)
    expect(isPreviewableImage('IMAGE/PNG')).toBe(true)
    expect(isPreviewableImage('text/plain; charset=utf-8')).toBe(false)
    expect(isPreviewableImage('application/pdf')).toBe(false)
  })
  it('basenameOfPath takes the last segment', () => {
    expect(basenameOfPath('/a/b/c.jpg')).toBe('c.jpg')
    expect(basenameOfPath('c.jpg')).toBe('c.jpg')
  })
  it('formatBytes renders B/KB/MB', () => {
    expect(formatBytes(11)).toBe('11 B')
    expect(formatBytes(48211)).toBe('47.1 KB')
    expect(formatBytes(50 * 1024 * 1024)).toBe('50.0 MB')
  })
})

/**  * `set_pull_request` — the payload has exactly two success shapes plus the error shape. These cases
 * are copied from real rows in the live DB (`llm_history.response_content`) so the parser is pinned
 * to the wire, not to a guess about it. */
describe('parseSetPullRequest', () => {
  const ATTACH_GITHUB = {
    session_id: 'task_1791883461055_3',
    attached: true,
    url: 'https://github.com/ginwa123/pabrik/pull/922',
    provider: 'github',
    number: '922',
    verified: true,
    warning: null,
    base: null,
    head: null,
  }

  it('reads the attach payload field-for-field', () => {
    const r = parseSetPullRequest(ATTACH_GITHUB)
    expect(r).toEqual({
      url: 'https://github.com/ginwa123/pabrik/pull/922',
      provider: 'github',
      number: '922',
      attached: true,
      cleared: false,
      verified: true,
      warning: null,
      base: null,
      head: null,
      sessionId: 'task_1791883461055_3',
      success: true,
      error: null,
    })
  })

  it('keeps a non-numeric IID as a string (GitLab/patchset numbering)', () => {
    const r = parseSetPullRequest({ ...ATTACH_GITHUB, provider: 'gitlab', number: '7a' })
    expect(r.number).toBe('7a')
  })

  it('surfaces a degraded bind: verified=false with a warning', () => {
    const r = parseSetPullRequest({
      ...ATTACH_GITHUB,
      provider: 'generic',
      number: null,
      verified: false,
      warning: 'gh CLI not found; bound without verification',
    })
    expect(r.verified).toBe(false)
    expect(r.number).toBeNull()
    expect(r.warning).toContain('without verification')
    expect(r.success).toBe(true)
  })

  it('reads the clear payload ({session_id, cleared:true})', () => {
    const r = parseSetPullRequest({ session_id: 'task_1', cleared: true })
    expect(r.cleared).toBe(true)
    expect(r.attached).toBe(false)
    expect(r.url).toBeNull()
    expect(r.success).toBe(true)
  })

  it('reads the error payload', () => {
    const r = parseSetPullRequest({ error: 'PR verification failed: no such PR' })
    expect(r.success).toBe(false)
    expect(r.error).toBe('PR verification failed: no such PR')
  })

  it('unwraps a full envelope as well as the bare data payload', () => {
    const envelope = JSON.stringify({
      tool: 'set_pull_request',
      parameters: { pr_url: ATTACH_GITHUB.url },
      success: true,
      data: ATTACH_GITHUB,
      error: null,
      v: 1,
    })
    expect(parseSetPullRequest(envelope).number).toBe('922')
    expect(parseSetPullRequest(ATTACH_GITHUB).number).toBe('922')
  })

  it('never throws on empty or non-object content', () => {
    for (const input of [null, undefined, '', 'not json', 42, []]) {
      const r = parseSetPullRequest(input)
      expect(r.url).toBeNull()
      expect(r.success).toBe(true)
    }
  })
})

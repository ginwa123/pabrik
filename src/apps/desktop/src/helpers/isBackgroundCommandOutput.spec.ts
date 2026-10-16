import { describe, it, expect } from 'vitest'
import {
  parseBackgroundCommandOutput,
  isBackgroundCommandOutput,
  backgroundToShellXml,
} from './isBackgroundCommandOutput'

const xmlEnvelope = (
  pid: string,
  command: string,
  stdout: string,
  truncated = false,
  extra = '',
) =>
  '<background_command>\n' +
  `<pid>${pid}</pid>\n` +
  `<command>${command}</command>\n` +
  `<stdout>${stdout}</stdout>\n` +
  `<truncated>${truncated}</truncated>\n` +
  extra +
  '</background_command>'

// ============================================================================
// The JSON envelope — the shape the backend emits TODAY
// ============================================================================
//
// Its absence is the bug this block exists for. `buildCompletionMessage`
// (src/agentic_loop/background_process.zig) has emitted JSON since #563 and
// `background_command_completion_test.zig` asserts that JSON; this parser only
// knew the XML and the legacy prose, so every completion since then rendered as
// raw JSON in a user bubble. Two green suites, one broken product.
//
// The literal below is written out BY HAND in the backend's field order
// (`pid`, `command`, `stdout`, `truncated`, `total_bytes`, `log_path`, from
// `std.json.Stringify`) rather than built by a helper, because a helper here
// would let the two sides drift again while both stayed green. When the
// backend's shape changes, this literal is the thing that fails.
const jsonEnvelope = (pid: number, command: string, stdout: string) =>
  `{"pid":${pid},"command":${JSON.stringify(command)},"stdout":${JSON.stringify(stdout)},"truncated":false,"total_bytes":null,"log_path":null}`

/** Truncated: both extra fields are populated. */
const jsonEnvelopeTruncated = (pid: number, command: string, stdout: string, total: number, log: string) =>
  `{"pid":${pid},"command":${JSON.stringify(command)},"stdout":${JSON.stringify(stdout)},"truncated":true,"total_bytes":${total},"log_path":${JSON.stringify(log)}}`

describe('isBackgroundCommandOutput (JSON envelope)', () => {
  it('parses the current JSON envelope', () => {
    const content = jsonEnvelope(1234, 'sleep 10', 'hello\nworld')
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toEqual({
      pid: '1234',
      command: 'sleep 10',
      body: 'hello\nworld',
      truncated: false,
      logPath: null,
    })
  })

  it('parses the truncated variant with its log path', () => {
    const content = jsonEnvelopeTruncated(7, 'make', 'partial', 99999, '/tmp/full.log')
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.pid).toBe('7')
    expect(parsed!.truncated).toBe(true)
    expect(parsed!.logPath).toBe('/tmp/full.log')
    expect(parsed!.body).toBe('partial')
  })

  it('keeps quotes and backslashes verbatim (JSON escaping, no entity layer)', () => {
    // The XML shape needed an entity layer for exactly this content; JSON does
    // not, so the card must show the real characters.
    const content = jsonEnvelope(9, "echo \"a<b>&c\"", 'it\'s "done" & <not> a tag')
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.command).toBe('echo "a<b>&c"')
    expect(parsed!.body).toBe('it\'s "done" & <not> a tag')
  })

  it('accepts a string pid — the backend writes a number, a replayed row may not', () => {
    const content = '{"pid":"42","command":"x","stdout":"y","truncated":false,"total_bytes":null,"log_path":null}'
    expect(parseBackgroundCommandOutput(content)?.pid).toBe('42')
  })

  it('detects the JSON envelope but returns null when it is not one of ours', () => {
    // Same contract as a malformed `<background_command>` block: the PREDICATE says "this is an
    // envelope" (so the bubble is not rendered as prose) and the PARSER says "I cannot shape it"
    // (so no card). A JSON object with no `pid` is somebody else's data.
    const content = '{"pid":'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('ignores ordinary messages that merely contain a brace', () => {
    expect(isBackgroundCommandOutput('what does {"a":1} mean?')).toBe(false)
    expect(isBackgroundCommandOutput(JSON.stringify({ hello: 'world' }))).toBe(false)
    expect(parseBackgroundCommandOutput(JSON.stringify({ hello: 'world' }))).toBeNull()
  })

  it('permanently NOT a JSON envelope: a plain sentence', () => {
    expect(parseBackgroundCommandOutput('please fix the login bug')).toBeNull()
  })
})

describe('isBackgroundCommandOutput', () => {
  it('parses XML happy path pid/command/body', () => {
    const content = xmlEnvelope('12345', 'sleep 10', 'hello world')
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toEqual({
      pid: '12345',
      command: 'sleep 10',
      body: 'hello world',
      truncated: false,
      logPath: null,
    })
  })

  it('parses XML body with newlines and truncation fields', () => {
    const content = xmlEnvelope(
      '7',
      'make',
      'line one\nline two',
      true,
      '<total_bytes>99999</total_bytes>\n<log_path>/tmp/full.log</log_path>\n',
    )
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.pid).toBe('7')
    expect(parsed!.body).toBe('line one\nline two')
    expect(parsed!.truncated).toBe(true)
    expect(parsed!.logPath).toBe('/tmp/full.log')
  })

  it('unescapes XML entities in command/body', () => {
    const content = xmlEnvelope(
      '9',
      'echo &lt;a&gt;&amp;',
      'it&apos;s &quot;done&quot;',
    )
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.command).toBe('echo <a>&')
    expect(parsed!.body).toBe(`it's "done"`)
  })

  it('returns null for XML missing required tags', () => {
    const content = '<background_command>\n<pid>1</pid>\n</background_command>'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('parses legacy prose envelope as fallback', () => {
    const content =
      'This is an output from background command (pid 12345, command `sleep 10`):\n' +
      '"""""\n' +
      'hello world\n' +
      '"""""'
    expect(isBackgroundCommandOutput(content)).toBe(true)
    expect(parseBackgroundCommandOutput(content)).toEqual({
      pid: '12345',
      command: 'sleep 10',
      body: 'hello world',
      truncated: false,
      logPath: null,
    })
  })

  it('preserves a legacy body that starts with an exit-like line verbatim', () => {
    const content =
      'This is an output from background command (pid 8, command `make`):\n' +
      '"""""\n' +
      '(exit 0, stdout tail)\nreal output\n' +
      '"""""'
    const parsed = parseBackgroundCommandOutput(content)
    expect(parsed).not.toBeNull()
    expect(parsed!.body).toBe('(exit 0, stdout tail)\nreal output')
  })

  it('returns null for ordinary user text', () => {
    const content = 'hey, can you help me with this bug?'
    expect(isBackgroundCommandOutput(content)).toBe(false)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('returns null for foreground <command> XML', () => {
    const content =
      '<command>echo hi</command><stdout>hi</stdout><stderr></stderr>' +
      '<exit_code>0</exit_code><truncated>false</truncated><timeout>false</timeout>' +
      '<stdout_lines></stdout_lines><stderr_lines></stderr_lines>'
    expect(isBackgroundCommandOutput(content)).toBe(false)
    expect(parseBackgroundCommandOutput(content)).toBeNull()
  })

  it('backgroundToShellXml contains escaped command/stdout tags', () => {
    const xml = backgroundToShellXml({
      pid: '123',
      command: 'echo "a<b>&c"',
      body: "it's <done> & \"dusted\"",
      truncated: true,
      logPath: '/tmp/full.log',
    })
    expect(xml).toContain('<command>echo &quot;a&lt;b&gt;&amp;c&quot;</command>')
    expect(xml).toContain('<stdout>it&apos;s &lt;done&gt; &amp; &quot;dusted&quot;</stdout>')
    expect(xml).toContain('<stderr></stderr>')
    expect(xml).toContain('<truncated>true</truncated>')
  })
})

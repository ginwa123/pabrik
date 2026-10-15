/** Phase 0 RED contract for the XML → JSON tool-output migration
 * (plan `2026-09-18-agent-tool-output-xml-to-json.md`, schema in
 * `2026-09-18-agent-tool-output-json-schema.md`).
 * Asserts the JSON-only `unwrapToolOutput` target shape. FAILS while the
 * implementation still parses `<tool>…</tool>` XML (RED); Phase 3 makes it
 * green. Fixtures: `tests/fixtures/tool_output/json/`. */
import { describe, expect, it } from 'vitest'
import { unwrapToolOutput, tryUnwrapToolOutput } from './unwrapToolOutput'

const successEnvelope = JSON.stringify({
  tool: 'read_file',
  parameters: { path: '/x.txt' },
  success: true,
  data: { path: '/x.txt', content: 'foo\nbar\n', total_lines: 2, start_line: 0, end_line: 1 },
  error: null,
  v: 1,
})

const errorEnvelope = JSON.stringify({
  tool: 'read_file',
  parameters: { path: '/missing' },
  success: false,
  data: null,
  error: 'File not found',
  v: 1,
})

describe('unwrapToolOutput JSON contract', () => {
  it('parses a success envelope with object data and re-stringified parameters', () => {
    const out = unwrapToolOutput(successEnvelope)
    expect(out.name).toBe('read_file')
    expect(JSON.parse(out.parameters)).toEqual({ path: '/x.txt' })
    expect(out.success).toBe(true)
    expect(out.error).toBeNull()
    expect(out.data).toEqual({
      path: '/x.txt',
      content: 'foo\nbar\n',
      total_lines: 2,
      start_line: 0,
      end_line: 1,
    })
  })

  it('parses an error envelope with null data and string error', () => {
    const out = unwrapToolOutput(errorEnvelope)
    expect(out.success).toBe(false)
    expect(out.data).toBeNull()
    expect(out.error).toBe('File not found')
  })

  it('throws MalformedToolEnvelope on legacy XML input (no fallback)', () => {
    expect(() =>
      unwrapToolOutput(
        '<tool><name>read_file</name><parameters></parameters><success>true</success></tool>',
      ),
    ).toThrow(/MalformedToolEnvelope/)
  })

  it('tryUnwrap returns null on garbage', () => {
    expect(tryUnwrapToolOutput('not json at all {{{')).toBeNull()
  })

  it('preserves <>& characters inside data without entity decoding', () => {
    const raw = JSON.stringify({
      tool: 'bash',
      parameters: {},
      success: true,
      data: { stdout: '<hi> & "world"' },
      error: null,
      v: 1,
    })
    const out = unwrapToolOutput(raw)
    expect((out.data as { stdout: string }).stdout).toBe('<hi> & "world"')
  })
})

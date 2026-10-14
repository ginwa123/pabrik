/**
 * Tests for ShellTool.vue — in-progress (placeholder) rendering.
 *
 * Regression: while a shell tool (bash/pwsh/command) is still running,
 * the backend has only emitted the Phase-1 placeholder envelope
 * (handle_tool.zig: empty `<data></data>`). ShellTool only read
 * `:content` (inner data) so `parsed.command` was null and the header
 * showed `$ unknown` for the whole run (screenshot: `command $ unknown +`).
 *
 * The tool-call arguments (JSON `{"command":"..."}`) ARE available in
 * the outer `<tool><parameters>` envelope — ChatView unwraps them via
 * `getParametersForMessage`. ShellTool must accept `:parameters` and
 * fall back to `parameters.command` while in-progress, with a running
 * indicator, instead of `unknown`.
 */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import ShellTool from '../ShellTool.vue'

const completedEnvelope = {
  command: 'echo hi',
  stdout: 'hi',
  stderr: '',
  exit_code: 0,
  truncated: false,
  timeout: false,
  stdout_lines: 1,
  stderr_lines: 0,
}

const emptyPlaceholder = ''

/**
 * The exact `response_content` the backend persisted for the four failed
 * calls in session task_1790447864669_3 (llm_history row 1790452019027732862
 * and its three siblings). The model asked for the pre-2026-09-04 `bash`
 * tool, Phase 3 skipped the call, and this is what was left behind.
 */
const unknownToolEnvelope = JSON.stringify({
  tool: 'bash',
  parameters: {
    command: 'timeout 900 zig build web 2>&1 | head -60',
    cwd: '/home/ginwa/.config/pabrik/.worktrees/glinlandui-web',
    timeout: 950,
    max_lines: 70,
  },
  success: false,
  data: null,
  error:
    "unknown tool 'bash' — it is not available in this session; do not call it again. Available tools: command,read_file,...",
  v: 1,
})

const paramsFor = (command: string) => JSON.stringify({ command })

const makeWrapper = (props: {
  content: unknown
  toolName?: string
  parameters?: string
  expanded?: boolean
}) =>
  mount(ShellTool, {
    props: {
      toolName: 'command',
      ...props,
    } as never,
  })

afterEach(() => {
  document.body.innerHTML = ''
})

describe('ShellTool.vue — in-progress placeholder (TDD: unknown bug)', () => {
  it('shows the command from :parameters when :content is empty (running), not "unknown"', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: paramsFor('sleep 10'),
    })
    const html = wrapper.html()
    expect(html).toContain('sleep 10')
    expect(html).not.toContain('unknown')
  })

  it('shows a running indicator while exit_code is missing (in-progress)', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: paramsFor('sleep 10'),
    })
    const html = wrapper.html()
    // running badge — exact copy is "running" (pulsing dot via CSS)
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers :content command over :parameters once completed', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: paramsFor('stale command from args'),
    })
    const html = wrapper.html()
    expect(html).toContain('echo hi')
    expect(html).not.toContain('stale command from args')
  })

  it('falls back to "unknown" only when BOTH content and parameters lack a command', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: '{}',
    })
    expect(wrapper.html()).toContain('unknown')
  })

  it('does NOT show the running indicator once exit_code is present (completed)', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: paramsFor('echo hi'),
    })
    expect(wrapper.html().toLowerCase()).not.toContain('running')
  })

  it('shows command from JSON :parameters when :content empty', () => {
    const wrapper = makeWrapper({
      content: emptyPlaceholder,
      parameters: '{"command":"sleep 10","timeout":30}',
    })
    const html = wrapper.html()
    expect(html).toContain('sleep 10')
    expect(html).not.toContain('unknown')
    expect(html.toLowerCase()).toContain('running')
  })

  it('prefers envelope command over JSON parameters', () => {
    const wrapper = makeWrapper({
      content: completedEnvelope,
      parameters: '{"command":"stale"}',
    })
    const html = wrapper.html()
    expect(html).toContain('echo hi')
    expect(html).not.toContain('stale')
  })
})

/**
 * Regression: a `success:false` shell envelope used to render as a card with
 * a pill, a command line, and nothing else — `normalized.error` was computed
 * and then read by nobody. A tool call that NEVER RAN was therefore
 * pixel-identical to a command that ran and printed nothing, which is how
 * four dead `bash` calls were read as "the shell is flaky" (the agent's own
 * diagnosis) instead of "that tool does not exist".
 */
/**
 * Regression: a `dotnet build` piped through PowerShell rendered as a wall
 * of `?[7mwarning ?[0m` (user screenshot). MSBuild colourises its
 * diagnostics even onto a pipe, so the captured stdout carried raw
 * `ESC[7m` sequences. These assert the card shows the DIAGNOSTIC, not the
 * escape soup — i.e. the exact user-visible symptom, driven through the
 * real component.
 */
describe('ShellTool.vue — ANSI escape soup never reaches the card', () => {
  const msbuildStdout =
    'C:\\Users\\gilang.trisetya\\AppData\\Local\\Microsoft\\dotnet\\sdk\\10.0.401\\Microsoft.Common.CurrentVersion.targets(4919,5): ' +
    '\x1b[7mwarning \x1b[0m\x1b[1mMSB\x1b[0m3026: Could not copy the file'

  it('renders the warning as readable prose', () => {
    const wrapper = makeWrapper({
      content: {
        ...completedEnvelope,
        command: 'dotnet build PriceCatalog.csproj',
        stdout: msbuildStdout,
        exit_code: 1,
      },
      expanded: true,
    })
    const card = wrapper.text()
    expect(card).toContain('warning MSB3026: Could not copy the file')
    expect(card).toContain('Microsoft.Common.CurrentVersion.targets(4919,5)')
  })

  it('renders no ESC byte, no "[7m"/"[0m" fragment and no replacement char', () => {
    const wrapper = makeWrapper({
      content: { ...completedEnvelope, stdout: msbuildStdout, exit_code: 1 },
      expanded: true,
    })
    const card = wrapper.text()
    expect(card).not.toContain('\x1b')
    expect(card).not.toContain('[7m')
    expect(card).not.toContain('[0m')
    expect(card).not.toContain('�')
  })

  it('strips escape sequences out of stderr too', () => {
    const wrapper = makeWrapper({
      content: {
        ...completedEnvelope,
        stdout: '',
        stderr: '\x1b[1mFAILED\x1b[0m \x1b[31mPriceCatalog.dll is locked\x1b[0m',
        exit_code: 1,
      },
      expanded: true,
    })
    const card = wrapper.text()
    expect(card).toContain('FAILED PriceCatalog.dll is locked')
    expect(card).not.toContain('[31m')
    expect(card).not.toContain('\x1b')
  })
})

describe('ShellTool.vue — failed envelope is never blank', () => {
  it('renders the envelope error text for a tool that never ran', () => {
    const wrapper = makeWrapper({ content: unknownToolEnvelope, toolName: 'bash' })
    const error = wrapper.find('[data-testid="shell-tool-error"]')
    expect(error.exists()).toBe(true)
    expect(error.text()).toContain("unknown tool 'bash'")
    // The actionable part: the model/human can see the canonical name.
    expect(error.text()).toContain('Available tools:')
  })

  it('marks the card as failed in the header even when collapsed', () => {
    const wrapper = makeWrapper({ content: unknownToolEnvelope, toolName: 'bash' })
    expect(wrapper.find('[data-testid="shell-tool-failed"]').exists()).toBe(true)
  })

  it('forces the body open — the error must not hide behind a "+"', () => {
    // No `expanded` prop: the collapsed state is the default the user saw.
    const wrapper = makeWrapper({ content: unknownToolEnvelope, toolName: 'bash' })
    expect(wrapper.find('[data-testid="shell-tool-error"]').exists()).toBe(true)
  })

  it('shows no error block for a successful command', () => {
    const wrapper = makeWrapper({ content: completedEnvelope, expanded: true })
    expect(wrapper.find('[data-testid="shell-tool-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="shell-tool-failed"]').exists()).toBe(false)
  })

  it('still surfaces a non-zero exit code as an error, with the exit code kept', () => {
    const wrapper = makeWrapper({
      content: { ...completedEnvelope, exit_code: 2, stderr: 'boom' },
      expanded: true,
    })
    // exit_code:2 with empty `error` field → no envelope-error block; the
    // existing exit-code badge remains the failure signal.
    expect(wrapper.find('[data-testid="shell-tool-error"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="shell-tool-exit-code"]').text()).toBe('2')
  })
})

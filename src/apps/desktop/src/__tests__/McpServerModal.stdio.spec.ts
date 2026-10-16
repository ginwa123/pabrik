import { mount, type VueWrapper } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

import McpServerModal, { type McpServerModalValue } from '../components/pabrik/McpServerModal.vue'

// Mock the `testMcpServer` API client so the modal's "Test" button tests don't hit the network. The
// mock is per-test (vi.resetMocks) so each test can shape its own response shape.
const mockTestMcpServer = vi.fn(async () => ({
  ok: true as const,
  transport: 'stdio' as const,
  tools: [
    { name: 'print_hello', description: 'Says hi' },
    { name: 'print_name', description: 'Server identity' },
  ],
}))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  // Forward all arguments to the mock so we can still assert on the
  // body via `mockTestMcpServer.mock.calls`. Cast through unknown
  // because the production function signature uses a typed object.
  return {
    ...actual,
    testMcpServer: (...args: unknown[]) =>
      mockTestMcpServer(...(args as Parameters<typeof mockTestMcpServer>)),
  }
})

const baseStdioServer: McpServerModalValue = {
  name: 'hello',
  transport: 'stdio',
  command: 'mcp-hello-world',
  args: [],
  env: [],
  cwd: '',
  url: '',
  headers: [],
}

const baseHttpServer: McpServerModalValue = {
  name: 'context7',
  transport: 'http',
  url: 'https://mcp.context7.com/mcp',
  headers: [],
  command: '',
  args: [],
  env: [],
  cwd: '',
}

/** Both branches of McpServerModal use <Teleport to="body">: the HTTP branch delegates to
 * <LlmConfigModal>, the stdio branch has its own bespoke centered dialog with backdrop + close ✕. */
/** Tests MUST use `document.body.querySelector` for teleported elements (NOT `wrapper.find`) and
 * `mount({ attachTo: document.body })` so the teleported DOM lands on the same body the queries
 * walk. */
function mountModal(
  value: McpServerModalValue,
  mode: 'add' | 'edit' = 'add',
): VueWrapper {
  return mount(McpServerModal, {
    props: { modelValue: value, mode },
    attachTo: document.body,
  })
}

describe('McpServerModal — stdio transport', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // Reset the mocked testMcpServer to its default success shape
    // before every test so a previous test's override doesn't leak.
    mockTestMcpServer.mockClear()
    mockTestMcpServer.mockResolvedValue({
      ok: true,
      transport: 'stdio',
      tools: [
        { name: 'print_hello', description: 'Says hi' },
        { name: 'print_name', description: 'Server identity' },
      ],
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Defensive: the Teleport-target content can survive between tests
    // if unmount() doesn't fully clean it. Force-remove both the
    // stdio + http modal teleport-landmarks so each test starts fresh.
    document.querySelectorAll(
      '[data-testid="stdio-modal-backdrop"], [data-testid="stdio-modal-dialog"], [data-testid="http-modal-backdrop"], [data-testid="http-modal-dialog"], [role="dialog"]',
    ).forEach((el) => el.remove())
  })

  it('renders stdio fields inside a centered modal (teleported to body)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-backdrop"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="name-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="command-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="args-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="env-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cwd-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="save-btn"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cancel-btn"]')).not.toBeNull()
  })

  it('shows "Add MCP server" title in add mode, "Edit MCP server" in edit mode', async () => {
    wrapper = mountModal(baseStdioServer, 'add')
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')?.textContent).toContain('Add MCP server')

    wrapper.unmount()
    wrapper = null
    // Force-clear leftover DOM since we manually unmount before the next mount.
    document.querySelectorAll('[data-testid="stdio-modal-backdrop"], [data-testid="stdio-modal-dialog"]').forEach((el) => el.remove())

    wrapper = mountModal(baseStdioServer, 'edit')
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')?.textContent).toContain('Edit MCP server')
  })

  it('shows transport toggle with stdio branch active by default when transport=stdio', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    // The toggle itself is teleported to body too. Query via document.body.
    expect(document.body.querySelector('[data-testid="transport-toggle-stdio"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="transport-toggle-http"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="command-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="args-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="env-textarea"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="cwd-input"]')).not.toBeNull()
    // URL field (HTTP branch, url-input) MUST NOT be in the DOM when
    // the stdio branch is mounted (branches are exclusive).
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()
  })

  it('shows URL + headers fields when transport=http', async () => {
    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    // HTTP branch is a bespoke dialog (Name + URL + Headers only) —
    // it must NOT render LlmConfigForm's LLM profile fields.
    expect(document.body.querySelector('[data-testid="http-modal-backdrop"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="http-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="url-input"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="name-input"]')).not.toBeNull()
    // Headers editor is present (empty-state hint).
    expect(document.body.textContent).toContain('No headers')
    // LLM profile fields must be absent.
    expect(document.body.querySelector('[data-testid="model-input"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="api-key-input"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="reasoning-effort-select"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="profile-capacity-input"]')).toBeNull()
    // Stdio dialog landmarks are absent (branches are exclusive).
    expect(document.body.querySelector('[data-testid="stdio-modal-backdrop"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).toBeNull()
  })

  it('switching to HTTP hides the stdio dialog and shows the HTTP modal', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="base-url-input"]')).toBeNull()

    // Click the HTTP toggle button in the teleported DOM (native click).
    const httpBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="transport-toggle-http"]',
    )
    expect(httpBtn).not.toBeNull()
    httpBtn!.click()
    await wrapper.vm.$nextTick()

    // StdIO dialog unmounts; HTTP dialog teleports in its place.
    expect(document.body.querySelector('[data-testid="stdio-modal-dialog"]')).toBeNull()
    expect(document.body.querySelector('[data-testid="http-modal-dialog"]')).not.toBeNull()
    expect(document.body.querySelector('[data-testid="url-input"]')).not.toBeNull()
  })

  it('emits cancel when the close ✕ button is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const closeBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="stdio-close-btn"]',
    )
    expect(closeBtn).not.toBeNull()
    closeBtn!.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('emits cancel when the backdrop is clicked (not on the dialog itself)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const backdrop = document.body.querySelector<HTMLElement>(
      '[data-testid="stdio-modal-backdrop"]',
    )
    expect(backdrop).not.toBeNull()
    backdrop!.click()   // click directly on the backdrop element
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('does NOT emit cancel when clicking on the dialog body (only on backdrop)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const dialog = document.body.querySelector<HTMLElement>(
      '[data-testid="stdio-modal-dialog"]',
    )!
    dialog.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeFalsy()
  })

  it('emits cancel when the footer Cancel button is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const cancelBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="cancel-btn"]',
    )!
    cancelBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('rejects save when command is empty in stdio mode', async () => {
    wrapper = mountModal({ ...baseStdioServer, command: '' })
    await wrapper.vm.$nextTick()
    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    expect(saveBtn.disabled).toBe(true)
    saveBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('save')).toBeFalsy()
  })

  it('emits save when Command is present and footer Save is clicked', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    expect(saveBtn.disabled).toBe(false)
    saveBtn.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.emitted('save')).toBeTruthy()
  })

  it('parses args textarea (newline-separated) on save', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const textarea = document.body.querySelector<HTMLTextAreaElement>(
      '[data-testid="args-textarea"]',
    )!
    // Native setter + dispatch 'input' to trigger v-model updates.
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype,
      'value',
    )!.set!
    setter.call(textarea, 'server.js\n--port\n3001')
    textarea.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()

    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    saveBtn.click()
    await wrapper.vm.$nextTick()

    // Modal emits the parsed args array back via update:modelValue
    // BEFORE the save event. The parent (PabrikConfigEditor.vue) sees
    // the parsed array on the modelValue and can persist it.
    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.args).toEqual(['server.js', '--port', '3001'])
  })

  it('parses env textarea (KEY=VALUE per line) on save', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const textarea = document.body.querySelector<HTMLTextAreaElement>(
      '[data-testid="env-textarea"]',
    )!
    const setter = Object.getOwnPropertyDescriptor(
      HTMLTextAreaElement.prototype,
      'value',
    )!.set!
    setter.call(textarea, 'NODE_ENV=production\nDEBUG=1')
    textarea.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()

    const saveBtn = document.body.querySelector<HTMLButtonElement>(
      '[data-testid="save-btn"]',
    )!
    saveBtn.click()
    await wrapper.vm.$nextTick()

    const updates = wrapper.emitted('update:modelValue') ?? []
    const last = updates[updates.length - 1]?.[0] as McpServerModalValue | undefined
    expect(last).toBeTruthy()
    expect(last!.env).toEqual(['NODE_ENV=production', 'DEBUG=1'])
  })

  // ── "Test" button tests ────────────────────────────────────────────── The Test button fires
  // `POST /api/mcp/test` against the current form contents (NOT the parent-managed modelValue — the
  // user tests what they see in the textareas).
  it('renders a Test button in the footer', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')
    expect(testBtn).not.toBeNull()
    expect(testBtn!.textContent?.trim()).toBe('Test')
    // Test is enabled when command is present.
    expect(testBtn!.disabled).toBe(false)
  })

  it('disables the Test button when command is empty', async () => {
    wrapper = mountModal({ ...baseStdioServer, command: '' })
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')
    expect(testBtn).not.toBeNull()
    expect(testBtn!.disabled).toBe(true)
  })

  it('clicking Test invokes testMcpServer with current textarea contents', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()

    // Type some args into the textarea BEFORE clicking Test — the
    // modal must send the textarea state, not the stale modelValue
    // (which the parent only refreshes on Save).
    const textarea = document.body.querySelector<HTMLTextAreaElement>(
      '[data-testid="args-textarea"]',
    )!
    const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')!.set!
    setter.call(textarea, 'server.js\n--port\n3001')
    textarea.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()

    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    // Let the mocked promise resolve + flush microtasks.
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))

    expect(mockTestMcpServer).toHaveBeenCalledTimes(1)
    const firstCall = mockTestMcpServer.mock.calls[0] as unknown as
      readonly unknown[] | undefined
    expect(firstCall).toBeDefined()
    const callArgs = (firstCall?.[0] as unknown) as Record<string, unknown>
    expect(callArgs.transport).toBe('stdio')
    expect(callArgs.command).toBe(baseStdioServer.command)
    expect(callArgs.args).toEqual(['server.js', '--port', '3001'])
  })

  it('renders green check + tool list on test success', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))

    const resultEl = document.body.querySelector('[data-testid="test-result"]')
    expect(resultEl).not.toBeNull()
    expect(resultEl!.textContent).toContain('Connected')
    expect(resultEl!.textContent).toContain('2 tools')

    const toolItems = document.body.querySelectorAll('[data-testid="test-tools"] li')
    expect(toolItems.length).toBe(2)
    expect(toolItems[0]?.textContent?.trim()).toContain('print_hello')
    expect(toolItems[1]?.textContent?.trim()).toContain('print_name')

    // No error element rendered on success.
    expect(document.body.querySelector('[data-testid="test-error"]')).toBeNull()
  })

  it('renders red cross + error message on test failure', async () => {
    mockTestMcpServer.mockResolvedValueOnce({
      ok: false,
      error: 'failed to spawn child process',
      details: 'ChildSpawnFailed',
    } as never)

    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))

    const resultEl = document.body.querySelector('[data-testid="test-result"]')
    expect(resultEl).not.toBeNull()
    expect(resultEl!.textContent).toContain('Connection failed')

    const errorEl = document.body.querySelector('[data-testid="test-error"]')
    expect(errorEl).not.toBeNull()
    expect(errorEl!.textContent).toContain('failed to spawn child process')

    // Tool list NOT rendered on failure.
    expect(document.body.querySelector('[data-testid="test-tools"]')).toBeNull()
  })

  it('clears the test result when the user edits any form field', async () => {
    // The modal's watcher fires on `props.modelValue` changes. In the parent
    // (`PabrikConfigEditor.vue`) this is wired via v-model; in this isolated test we have to
    // manually re-feed the emitted `update:modelValue` payload back into the prop via setProps.
    const testState = ref<McpServerModalValue>({ ...baseStdioServer })
    wrapper = mount(McpServerModal, {
      props: {
        modelValue: testState.value,
        mode: 'add',
        'onUpdate:modelValue': (next: McpServerModalValue) => {
          testState.value = next
          // Re-feed via wrapper.setProps so the watcher observes
          // the new prop reference (Vue Test Utils treats the
          // emitted value as the source of truth, not the ref).
          wrapper?.setProps({ modelValue: next })
        },
      },
      attachTo: document.body,
    }) as VueWrapper
    await wrapper.vm.$nextTick()

    // Run a successful test first.
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))
    expect(document.body.querySelector('[data-testid="test-result"]')).not.toBeNull()

    // Now edit the command — the input event triggers the modal's `updateCommand` →
    // `update:modelValue` emit, the test bridge above re-feeds it into the prop, and the watcher
    // clears `testResult` to null.
    const commandInput = document.body.querySelector<HTMLInputElement>(
      '[data-testid="command-input"]',
    )!
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!
    setter.call(commandInput, 'different-command')
    commandInput.dispatchEvent(new Event('input'))
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()

    expect(document.body.querySelector('[data-testid="test-result"]')).toBeNull()
  })

  it('shows "Testing…" + disables button while probe is in-flight', async () => {
    // A promise we resolve manually so we can assert the in-flight
    // UI state without racing.
    let resolveProbe!: (value: unknown) => void
    mockTestMcpServer.mockReturnValueOnce(
      new Promise<unknown>((r) => { resolveProbe = r }) as ReturnType<typeof mockTestMcpServer>,
    )

    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()

    expect(testBtn.textContent?.trim()).toBe('Testing…')
    expect(testBtn.disabled).toBe(true)

    // Resolve the probe so the test cleanup doesn't hang on an
    // unresolved promise.
    resolveProbe({
      ok: true,
      transport: 'stdio',
      tools: [{ name: 'foo', description: 'bar' }],
    })
    await wrapper.vm.$nextTick()
  })

  // ── Regression: duplicate footer (task_1788495808955_0) ─────────────
  // PR #373 added a Test-button footer BEFORE the old Cancel+Save
  // footer but forgot to delete the old one — the stdio dialog
  // rendered two stacked footers (Test | Cancel Save / Cancel Save)
  // with duplicated data-testids. Exactly one of each button must
  // exist per open dialog.
  it('stdio branch renders exactly one footer (1 Test + 1 Cancel + 1 Save)', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelectorAll('[data-testid="test-btn"]').length).toBe(1)
    expect(document.body.querySelectorAll('[data-testid="cancel-btn"]').length).toBe(1)
    expect(document.body.querySelectorAll('[data-testid="save-btn"]').length).toBe(1)
  })

  // ── HTTP branch: bespoke dialog (no LLM fields) ──────────────────── The HTTP branch previously
  // delegated to LlmConfigModal, which renders the full LLM profile form (Model / Thinking /
  // Temperature / URL style / API key / compaction overrides).
  it('http branch renders exactly one footer (1 Test + 1 Cancel + 1 Save)', async () => {
    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelectorAll('[data-testid="test-btn"]').length).toBe(1)
    expect(document.body.querySelectorAll('[data-testid="cancel-btn"]').length).toBe(1)
    expect(document.body.querySelectorAll('[data-testid="save-btn"]').length).toBe(1)
  })

  it('http Test button is disabled when URL is empty, enabled when present', async () => {
    wrapper = mountModal({ ...baseHttpServer, url: '' })
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    expect(testBtn.disabled).toBe(true)

    wrapper.unmount()
    wrapper = null
    document.querySelectorAll('[data-testid="http-modal-backdrop"], [data-testid="http-modal-dialog"], [role="dialog"]').forEach((el) => el.remove())

    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    const testBtn2 = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    expect(testBtn2.disabled).toBe(false)
  })

  it('http Save is disabled when URL is empty, enabled when present', async () => {
    wrapper = mountModal({ ...baseHttpServer, url: '' })
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector<HTMLButtonElement>('[data-testid="save-btn"]')!.disabled).toBe(true)

    wrapper.unmount()
    wrapper = null
    document.querySelectorAll('[data-testid="http-modal-backdrop"], [data-testid="http-modal-dialog"], [role="dialog"]').forEach((el) => el.remove())

    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    expect(document.body.querySelector<HTMLButtonElement>('[data-testid="save-btn"]')!.disabled).toBe(false)
  })

  it('http clicking Test invokes testMcpServer with url + headers', async () => {
    wrapper = mountModal({
      ...baseHttpServer,
      headers: [{ key: 'Authorization', value: 'Bearer sk-123' }],
    })
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))

    expect(mockTestMcpServer).toHaveBeenCalledTimes(1)
    const firstCall = mockTestMcpServer.mock.calls[0] as unknown as
      readonly unknown[] | undefined
    expect(firstCall).toBeDefined()
    const callArgs = (firstCall?.[0] as unknown) as Record<string, unknown>
    expect(callArgs.transport).toBe('http')
    expect(callArgs.url).toBe(baseHttpServer.url)
    expect(callArgs.headers).toEqual({ Authorization: 'Bearer sk-123' })
  })

  it('http renders green check + tool list on test success', async () => {
    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    const testBtn = document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!
    testBtn.click()
    await wrapper.vm.$nextTick()
    await wrapper.vm.$nextTick()
    await new Promise((r) => setTimeout(r, 0))

    const resultEl = document.body.querySelector('[data-testid="test-result"]')
    expect(resultEl).not.toBeNull()
    expect(resultEl!.textContent).toContain('Connected')
  })

  // ── Enabled checkbox (both branches) ───────────────────────────────
  it('stdio branch renders the Enabled checkbox, checked by default', async () => {
    wrapper = mountModal(baseStdioServer)
    await wrapper.vm.$nextTick()
    const box = document.body.querySelector<HTMLInputElement>('[data-testid="enabled-checkbox"]')
    expect(box).not.toBeNull()
    expect(box!.checked).toBe(true)
    expect(document.body.textContent).toContain('Enabled (agent can call this server)')
  })

  it('http branch renders the Enabled checkbox, checked by default', async () => {
    wrapper = mountModal(baseHttpServer)
    await wrapper.vm.$nextTick()
    const box = document.body.querySelector<HTMLInputElement>('[data-testid="enabled-checkbox"]')
    expect(box).not.toBeNull()
    expect(box!.checked).toBe(true)
  })

  it('unchecking Enabled emits update:modelValue with enabled:false', async () => {
    wrapper = mountModal({ ...baseStdioServer, enabled: true })
    await wrapper.vm.$nextTick()
    const box = document.body.querySelector<HTMLInputElement>('[data-testid="enabled-checkbox"]')!
    box.checked = false
    box.dispatchEvent(new Event('change'))
    await wrapper.vm.$nextTick()
    const emitted = wrapper.emitted('update:modelValue')?.at(-1)?.[0] as { enabled?: boolean } | undefined
    expect(emitted).toMatchObject({ enabled: false })
  })
})

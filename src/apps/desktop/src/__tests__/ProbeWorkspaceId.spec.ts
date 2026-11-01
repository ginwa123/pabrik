import { mount, type VueWrapper } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { LlmTestResult, McpTestResult } from '../api'
import LlmConfigModal, { type LlmConfigModalValue } from '../components/pabrik/LlmConfigModal.vue'
import McpServerModal, { type McpServerModalValue } from '../components/pabrik/McpServerModal.vue'

/** A stored credential reference, assembled from pieces so this file never
 * carries the literal token in one string. */
const SECRET_REF = '{' + '{SECRETS:commandcodeapikey}' + '}'

const mockTestLlmProfile = vi.fn(
  async (_body: Record<string, unknown>): Promise<LlmTestResult> => ({
    ok: true,
    model: 'deepseek-v4',
    reply: 'ok',
    latency_ms: 12,
  }),
)
const mockTestMcpServer = vi.fn(
  async (_body: Record<string, unknown>): Promise<McpTestResult> => ({
    ok: true,
    transport: 'stdio',
    tools: [{ name: 'print_hello', description: 'Says hi' }],
  }),
)

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    testLlmProfile: (...args: unknown[]) =>
      mockTestLlmProfile(...(args as Parameters<typeof mockTestLlmProfile>)),
    testMcpServer: (...args: unknown[]) =>
      mockTestMcpServer(...(args as Parameters<typeof mockTestMcpServer>)),
  }
})

const llmValue: LlmConfigModalValue = {
  name: 'deepseek auto',
  config: {
    model: 'deepseek/deepseek-v4.1-flash',
    base_url: 'https://api.example.com/v1',
    thinking: 'auto',
    temperature: 'auto',
    url_style: 'openai',
    api_key: SECRET_REF,
    max_capacity_tokens: null,
    compaction_threshold_percent: null,
    thinking_budget_tokens: null,
    reasoning_effort: null,
  },
}

const stdioServer: McpServerModalValue = {
  name: 'files',
  transport: 'stdio',
  url: '',
  headers: [],
  command: 'npx',
  args: ['-y', 'server-files'],
  env: [`TOKEN=${SECRET_REF}`],
  cwd: '',
}

const httpServer: McpServerModalValue = {
  name: 'remote',
  transport: 'http',
  url: 'https://mcp.example.com/rpc',
  headers: [{ key: 'Authorization', value: `Bearer ${SECRET_REF}` }],
  command: '',
  args: [],
  env: [],
  cwd: '',
}

/** Both modals use <Teleport to="body">, so assertions read from the document. */
async function settle(wrapper: VueWrapper) {
  await wrapper.vm.$nextTick()
  await wrapper.vm.$nextTick()
  await new Promise((resolve) => setTimeout(resolve, 0))
}

describe('Test probes carry the workspace a secret must be resolved in', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    mockTestLlmProfile.mockClear()
    mockTestMcpServer.mockClear()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document
      .querySelectorAll(
        '[data-testid="stdio-modal-backdrop"], [data-testid="http-modal-backdrop"], [role="dialog"]',
      )
      .forEach((el) => el.remove())
  })

  it('the agent dialog probes with the workspace id beside the untouched placeholder', async () => {
    wrapper = mount(LlmConfigModal, {
      props: { modelValue: llmValue, title: 'Edit agent', nameEditable: false, workspaceId: 'ws_1' },
      attachTo: document.body,
    })
    await settle(wrapper)

    document.body.querySelector<HTMLButtonElement>('[data-testid="llm-test-btn"]')!.click()
    await settle(wrapper)

    expect(mockTestLlmProfile).toHaveBeenCalledTimes(1)
    expect(mockTestLlmProfile.mock.calls[0]?.[0]).toMatchObject({
      api_key: SECRET_REF,
      workspace_id: 'ws_1',
    })
  })

  it('the MCP stdio probe carries the workspace id and the env it will test', async () => {
    wrapper = mount(McpServerModal, {
      props: { modelValue: stdioServer, mode: 'edit', workspaceId: 'ws_1' },
      attachTo: document.body,
    })
    await settle(wrapper)

    document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!.click()
    await settle(wrapper)

    expect(mockTestMcpServer.mock.calls[0]?.[0]).toMatchObject({
      transport: 'stdio',
      env: [`TOKEN=${SECRET_REF}`],
      workspace_id: 'ws_1',
    })
  })

  it('the MCP http probe carries the workspace id and the header it will test', async () => {
    wrapper = mount(McpServerModal, {
      props: { modelValue: httpServer, mode: 'edit', workspaceId: 'ws_1' },
      attachTo: document.body,
    })
    await settle(wrapper)

    document.body.querySelector<HTMLButtonElement>('[data-testid="test-btn"]')!.click()
    await settle(wrapper)

    expect(mockTestMcpServer.mock.calls[0]?.[0]).toMatchObject({
      transport: 'http',
      headers: { Authorization: `Bearer ${SECRET_REF}` },
      workspace_id: 'ws_1',
    })
  })

  it('a user-scope probe leaves workspace_id out of the request body entirely', async () => {
    wrapper = mount(LlmConfigModal, {
      props: { modelValue: llmValue, title: 'Edit agent', nameEditable: false },
      attachTo: document.body,
    })
    await settle(wrapper)

    document.body.querySelector<HTMLButtonElement>('[data-testid="llm-test-btn"]')!.click()
    await settle(wrapper)

    const body = JSON.parse(JSON.stringify(mockTestLlmProfile.mock.calls[0]?.[0]))
    expect('workspace_id' in body).toBe(false)
  })
})

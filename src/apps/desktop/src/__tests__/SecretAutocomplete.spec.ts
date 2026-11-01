import { mount, type VueWrapper } from '@vue/test-utils'
import { defineComponent, h, ref } from 'vue'
import { describe, expect, it } from 'vitest'

import LlmConfigForm, { type LlmConfig } from '../components/pabrik/LlmConfigForm.vue'
import McpHeadersEditor, { type McpHeader } from '../components/pabrik/McpHeadersEditor.vue'
import McpServerModal, { type McpServerModalValue } from '../components/pabrik/McpServerModal.vue'
import { provideSecretNames } from '../helpers/secretNames'
import { SECRET_PLACEHOLDER_PREFIX, SECRET_PLACEHOLDER_SUFFIX } from '../helpers/secretPlaceholder'

const NAMES = ['GITHUB_TOKEN', 'STRIPE_API_KEY']

function placeholder(name: string): string {
  return SECRET_PLACEHOLDER_PREFIX + name + SECRET_PLACEHOLDER_SUFFIX
}

const baseConfig: LlmConfig = {
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  backend: 'http',
  config_dir: null,
  max_turns: null,
  opencode_agent: null,
  opencode_auto: null,
  max_capacity_tokens: null,
  compaction_threshold_percent: null,
  thinking_budget_tokens: null,
  reasoning_effort: null,
}

function hostAround(names: readonly string[], render: () => unknown): VueWrapper {
  const Host = defineComponent({
    setup() {
      provideSecretNames(names)
      return render
    },
  })
  return mount(Host as never) as VueWrapper
}

describe('secret autocomplete — MCP header value', () => {
  function mountEditor(names: readonly string[], rows: McpHeader[]) {
    const value = ref<McpHeader[]>(rows)
    const wrapper = hostAround(names, () =>
      h(McpHeadersEditor, {
        modelValue: value.value,
        'onUpdate:modelValue': (next: McpHeader[]) => {
          value.value = next
        },
      }),
    )
    return { wrapper, value }
  }

  it('offers the workspace secret names once the placeholder prefix is typed', async () => {
    const { wrapper } = mountEditor(NAMES, [{ key: 'Authorization', value: '' }])
    await wrapper.find('[data-testid="header-value-input"]').setValue(SECRET_PLACEHOLDER_PREFIX + 'GIT')

    const rows = wrapper.findAll('[data-testid="secret-suggestion"]')
    expect(rows).toHaveLength(1)
    expect(rows[0]?.attributes('data-secret-name')).toBe('GITHUB_TOKEN')
  })

  it('writes the placeholder, not the secret, into the header value on pick', async () => {
    const { wrapper, value } = mountEditor(NAMES, [{ key: 'Authorization', value: '' }])
    const input = wrapper.find('[data-testid="header-value-input"]')
    await input.setValue(SECRET_PLACEHOLDER_PREFIX + 'STRIPE')

    await wrapper.find('[data-testid="secret-suggestion"]').trigger('mousedown')

    expect(value.value[0]?.value).toBe(placeholder('STRIPE_API_KEY'))
    expect(value.value[0]?.key).toBe('Authorization')
  })

  it('shows no menu when the workspace has no secrets to offer', async () => {
    const { wrapper } = mountEditor([], [{ key: 'Authorization', value: '' }])
    await wrapper.find('[data-testid="header-value-input"]').setValue(SECRET_PLACEHOLDER_PREFIX)

    expect(wrapper.find('[data-testid="secret-suggestions"]').exists()).toBe(false)
  })

  it('shows no menu without a provider, so the field still accepts a plain credential', async () => {
    const wrapper = mount(McpHeadersEditor, {
      props: { modelValue: [{ key: 'Authorization', value: '' }] },
    })
    await wrapper.find('[data-testid="header-value-input"]').setValue(SECRET_PLACEHOLDER_PREFIX + 'GIT')

    expect(wrapper.find('[data-testid="secret-suggestions"]').exists()).toBe(false)
  })
})

describe('secret autocomplete — agent API key', () => {
  function mountForm(names: readonly string[]) {
    const value = ref<LlmConfig>({ ...baseConfig })
    const wrapper = hostAround(names, () =>
      h(LlmConfigForm, {
        modelValue: value.value,
        'onUpdate:modelValue': (next: LlmConfig) => {
          value.value = next
        },
      }),
    )
    return { wrapper, value }
  }

  it('offers the names in the API key field and stores the placeholder', async () => {
    const { wrapper, value } = mountForm(NAMES)
    const input = wrapper.find('[data-testid="api-key-input"]')
    await input.setValue(SECRET_PLACEHOLDER_PREFIX + 'GIT')

    const suggestion = wrapper.find('[data-testid="secret-suggestion"]')
    expect(suggestion.attributes('data-secret-name')).toBe('GITHUB_TOKEN')

    await suggestion.trigger('mousedown')
    expect(value.value.api_key).toBe(placeholder('GITHUB_TOKEN'))
  })

  it('accepts the highlighted row with the keyboard', async () => {
    const { wrapper, value } = mountForm(NAMES)
    const input = wrapper.find('[data-testid="api-key-input"]')
    await input.setValue(SECRET_PLACEHOLDER_PREFIX)

    await input.trigger('keydown', { key: 'ArrowDown' })
    await input.trigger('keydown', { key: 'Enter' })

    expect(value.value.api_key).toBe(placeholder('STRIPE_API_KEY'))
  })
})

describe('secret autocomplete — MCP stdio environment', () => {
  const stdio: McpServerModalValue = {
    name: 'files',
    transport: 'stdio',
    url: '',
    headers: [],
    command: 'mcp-files',
    args: [],
    env: [],
    cwd: '',
  }

  function mountModal(names: readonly string[]) {
    const value = ref<McpServerModalValue>({ ...stdio })
    const wrapper = hostAround(names, () =>
      h(McpServerModal, {
        modelValue: value.value,
        mode: 'add',
        'onUpdate:modelValue': (next: McpServerModalValue) => {
          value.value = next
        },
      }),
    )
    return { wrapper, value }
  }

  function envTextarea(): HTMLTextAreaElement {
    const el = document.body.querySelector('[data-testid="env-textarea"]')
    if (!el) throw new Error('env textarea not rendered')
    return el as HTMLTextAreaElement
  }

  function type(text: string): void {
    const el = envTextarea()
    el.value = text
    el.dispatchEvent(new Event('input'))
  }

  it('completes a placeholder inside one KEY=VALUE line', async () => {
    const { value } = mountModal(NAMES)
    await Promise.resolve()

    type(`TOKEN=${SECRET_PLACEHOLDER_PREFIX}STRIPE`)
    await Promise.resolve()

    const suggestion = document.body.querySelector('[data-testid="secret-suggestion"]')
    expect(suggestion?.getAttribute('data-secret-name')).toBe('STRIPE_API_KEY')

    suggestion?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await Promise.resolve()

    expect(envTextarea().value).toBe(`TOKEN=${placeholder('STRIPE_API_KEY')}`)

    // Saving parses the textarea, so the placeholder is what reaches the server.
    ;(document.body.querySelector('[data-testid="save-btn"]') as HTMLButtonElement).click()
    await Promise.resolve()
    expect(value.value.env).toEqual([`TOKEN=${placeholder('STRIPE_API_KEY')}`])
  })
})

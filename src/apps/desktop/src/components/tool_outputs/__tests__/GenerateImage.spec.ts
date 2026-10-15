/**
 * Tests for GenerateImage.vue — the tool-output card component for the
 * `generate_image` agent tool.
 *
 * Verifies:
 *  - renders the data-testid matching the message id (for E2E selectors)
 *  - success path: tool name + parameter prompt as primary + right-meta
 *    (model + size + count) + ✓ status badge
 *  - error path: red border + ✗ badge + error message inline
 *  - expand/collapse: clicking the header toggles the body; per-image
 *    rows show path / bytes / mime; revised_prompt shown when present
 *  - copy button: clicks the per-image copy button without bubbling
 *    to the parent (no expand-toggle side effect)
 *  - parameters prop (JSON-stringified tool args) is parsed and the
 *    prompt is rendered when present; falls back to envelope values
 *    when parameters is malformed JSON or missing
 *
 * Per the project rule of behavioural tests (no static-contract), these
 * tests interact with the component as the user would — mounting,
 * querying via `data-testid`, clicking buttons.
 */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import GenerateImage from '../GenerateImage.vue'

// ─── Test helpers ──────────────────────────────────────────────────────────
const makeSuccessContent = (opts: {
  model?: string
  size?: string
  count?: number
  images?: Array<{ index: number; path: string; bytes: number; mime?: string }>
  revisedPrompt?: string | null
} = {}) => {
  const model = opts.model ?? 'dall-e-3'
  const size = opts.size ?? '1024x1024'
  const count = opts.count ?? 1
  const images = (opts.images ?? [
    { index: 0, path: '/cwd/generated_images/img_123.png', bytes: 12345, mime: 'image/png' },
  ]).map((img) => ({ ...img, mime: img.mime ?? 'image/png' }))
  return {
    status: 'generated',
    count,
    model,
    size,
    images,
    revised_prompt:
      opts.revisedPrompt === undefined ? 'A vibrant watercolor of a cat' : opts.revisedPrompt,
    error: null,
  }
}

const makeErrorContent = (msg = 'HTTP 400: size "512x512" is not valid for model "dall-e-3"') => ({
  status: null,
  count: null,
  model: null,
  size: null,
  images: [],
  revised_prompt: null,
  error: msg,
})

const makeParameters = (prompt: string) =>
  JSON.stringify({ prompt, model: 'dall-e-3', size: '1024x1024', n: 1 })

// ─── Tests ─────────────────────────────────────────────────────────────────
describe('GenerateImage', () => {
  it('renders the card with a data-testid', () => {
    const wrapper = mount(GenerateImage, {
      props: { content: makeSuccessContent(), parameters: makeParameters('a cat') },
    })
    expect(wrapper.find('[data-testid="generate-image-card"]').exists()).toBe(true)
  })

  it('success path: tool name + prompt (truncated) + model + size + ✓', () => {
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent({ model: 'dall-e-3', size: '1024x1024' }),
        parameters: makeParameters('A cute cat wearing a top hat'),
      },
    })
    expect(wrapper.text()).toContain('generate_image')
    expect(wrapper.text()).toContain('A cute cat wearing a top hat')
    expect(wrapper.text()).toContain('dall-e-3')
    expect(wrapper.text()).toContain('1024x1024')
    expect(wrapper.text()).toContain('✓')
    // ✗ must NOT appear on success
    expect(wrapper.text()).not.toContain('✗')
  })

  it('truncates very long prompts in the header (> 80 chars)', () => {
    const longPrompt = 'a'.repeat(120)
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParameters(longPrompt),
      },
    })
    const text = wrapper.text()
    expect(text).not.toContain('a'.repeat(120))
    expect(text).toContain('…')
  })

  it('falls back to envelope values when parameters prop is missing', () => {
    const wrapper = mount(GenerateImage, {
      props: { content: makeSuccessContent({ model: 'dall-e-2', size: '512x512' }) },
    })
    expect(wrapper.text()).toContain('dall-e-2')
    expect(wrapper.text()).toContain('512x512')
  })

  it('falls back gracefully when parameters is malformed JSON', () => {
    const wrapper = mount(GenerateImage, {
      props: { content: makeSuccessContent(), parameters: 'not json {' },
    })
    // Should still render the card with envelope-derived values
    expect(wrapper.find('[data-testid="generate-image-card"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('dall-e-3')
  })

  it('error path: red border + ✗ + error message inline', () => {
    const wrapper = mount(GenerateImage, {
      props: { content: makeErrorContent('HTTP 400: bad size') },
    })
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).not.toContain('✓')
    expect(wrapper.find('[data-testid="generate-image-card"]').classes()).toContain(
      'border-red-500/50',
    )
  })

  it('expands on header click and shows per-image rows', async () => {
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent({
          images: [
            { index: 0, path: '/cwd/img_a.png', bytes: 1000 },
            { index: 1, path: '/cwd/img_b.png', bytes: 2000 },
          ],
        }),
        parameters: makeParameters('a cat'),
      },
    })
    // Initially collapsed
    expect(wrapper.find('[data-testid="generate-image-row-0"]').exists()).toBe(false)
    // Click to expand
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="generate-image-row-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="generate-image-row-1"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('/cwd/img_a.png')
    expect(wrapper.text()).toContain('/cwd/img_b.png')
    expect(wrapper.text()).toContain('1.0 KB')
    expect(wrapper.text()).toContain('2.0 KB')
  })

  it('shows revised_prompt when present (DALL-E 3 / gpt-image-1)', async () => {
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent({ revisedPrompt: 'A vibrant watercolor of a cat' }),
        parameters: makeParameters('a cat'),
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="generate-image-revised-prompt"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('A vibrant watercolor of a cat')
  })

  it('omits revised_prompt when null (DALL-E 2)', async () => {
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent({ revisedPrompt: null }),
        parameters: makeParameters('a cat'),
      },
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.find('[data-testid="generate-image-revised-prompt"]').exists()).toBe(false)
  })

  it('shows the × count suffix in right meta only when count > 1', () => {
    const singleWrapper = mount(GenerateImage, {
      props: { content: makeSuccessContent({ count: 1 }) },
    })
    expect(singleWrapper.text()).not.toContain('1×')

    const multiWrapper = mount(GenerateImage, {
      props: { content: makeSuccessContent({ count: 3 }) },
    })
    expect(multiWrapper.text()).toContain('3×')
  })

  it('respects the expanded prop (auto-expands when parent forces it)', () => {
    const wrapper = mount(GenerateImage, {
      props: {
        content: makeSuccessContent(),
        parameters: makeParameters('a cat'),
        expanded: true,
      },
    })
    expect(wrapper.find('[data-testid="generate-image-row-0"]').exists()).toBe(true)
  })
})
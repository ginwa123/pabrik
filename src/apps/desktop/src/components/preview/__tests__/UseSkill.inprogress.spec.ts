/** UseSkill.vue — the `use_skill` card. The tool call is `{ name }` and the payload is `{
 * skill_name, content, loaded, asset_dir, asset_count, error?, available_skills? }`. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import UseSkill from '../UseSkill.vue'

const loadedPayload = {
  skill_name: 'my-skill',
  content: '# my skill body',
  loaded: true,
  asset_dir: '/tmp/nalar-skill-assets-abc123',
  asset_count: 3,
  available_skills: null,
}

describe('UseSkill.vue — in-progress', () => {
  it('shows the name from :parameters when :content is empty, not unknown', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: null,
        parameters: JSON.stringify({ name: 'my-skill' }),
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('my-skill')
    expect(html).not.toContain('unknown')
  })

  it('still reads a legacy skill_name argument', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: null,
        parameters: JSON.stringify({ skill_name: 'legacy-skill' }),
      } as never,
    })
    expect(wrapper.html()).toContain('legacy-skill')
  })

  it('shows running badge while empty, hides once completed', () => {
    const running = mount(UseSkill, {
      props: {
        content: null,
        parameters: JSON.stringify({ name: 'my-skill' }),
      } as never,
    })
    expect(running.find('[data-testid="use-skill-running"]').exists()).toBe(true)
    const done = mount(UseSkill, {
      props: {
        content: loadedPayload,
        parameters: JSON.stringify({ name: 'my-skill' }),
      } as never,
    })
    expect(done.find('[data-testid="use-skill-running"]').exists()).toBe(false)
  })
})

describe('UseSkill.vue — loaded', () => {
  it('shows loaded content and status from the JSON payload', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: loadedPayload,
        expanded: true,
        parameters: JSON.stringify({ name: 'my-skill' }),
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('my-skill')
    expect(html).toContain('# my skill body')
    expect(html).toContain('✓')
  })

  it('does not render the materialised asset_dir', () => {
    // It is reaped per load, so printing it teaches the user a path that
    // will be gone by the time they look.
    const wrapper = mount(UseSkill, {
      props: { content: loadedPayload, expanded: true } as never,
    })
    expect(wrapper.html()).not.toContain('/tmp/nalar-skill-assets-abc123')
  })
})

describe('UseSkill.vue — refusals', () => {
  it('shows the error from the JSON payload', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: {
          skill_name: 'missing',
          content: '',
          loaded: false,
          asset_dir: null,
          asset_count: 0,
          error: 'no skill named "missing" in this workspace',
          available_skills: null,
        },
        expanded: true,
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('no skill named')
    expect(html).toContain('✗')
  })

  it('lists available_skills so the model can pick a real name', () => {
    const wrapper = mount(UseSkill, {
      props: {
        content: {
          skill_name: 'authent',
          content: '',
          loaded: false,
          asset_dir: null,
          asset_count: 0,
          error: 'no skill named "authent"',
          available_skills: ['auth', 'authz'],
        },
        expanded: true,
      } as never,
    })
    const html = wrapper.html()
    expect(html).toContain('no skill named')
    expect(html).toContain('auth')
    expect(html).toContain('authz')
    expect(html).toContain('2 available')
  })
})

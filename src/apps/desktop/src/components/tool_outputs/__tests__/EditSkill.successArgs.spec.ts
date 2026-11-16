import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import EditSkill from '../EditSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

const edited = { skill_name: 'my-skill', name: 'my-skill', updated: true, edited: true }

describe('EditSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(EditSkill, {
      props: {
        content: edited,
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('names the edited skill — there is no path to show', () => {
    const wrapper = mount(EditSkill, {
      props: {
        content: edited,
        parameters: '{"skill_name":"my-skill","content":"new body"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.find('[data-testid="edit-skill-name"]').text()).toContain('my-skill')
    expect(wrapper.text()).not.toContain('Path:')
    expect(wrapper.text()).not.toContain('SKILL.MD')
  })

  it('falls back to `name` when skill_name is empty', () => {
    // `''` is not null, so a `??` chain alone would let the blank win and render an unlabelled card.
    const wrapper = mount(EditSkill, {
      props: {
        content: { skill_name: '', name: 'my-skill', edited: true },
        parameters: '{"skill_name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('primary')).toBe('my-skill')
  })

  it('shows the error and is expandable on a refusal', () => {
    const wrapper = mount(EditSkill, {
      props: {
        content: { skill_name: 'ghost', edited: false, error: 'no such skill' },
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('no such skill')
    expect(wrapper.find('[data-testid="edit-skill-name"]').exists()).toBe(false)
  })
})

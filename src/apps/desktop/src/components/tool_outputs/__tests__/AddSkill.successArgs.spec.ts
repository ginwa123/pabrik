import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import AddSkill from '../AddSkill.vue'
import ToolCardHeader from '../_shared/ToolCardHeader.vue'

const created = { skill_name: 'my-skill', name: 'my-skill', created: true }

describe('AddSkill.vue — clean success with args is expandable', () => {
  it('header is expandable and expanded body shows Arguments', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: created,
        parameters: '{"name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('Arguments')
  })

  it('names the created skill — there is no path to show', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: created,
        parameters: '{"name":"my-skill","description":"d","content":"c"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.find('[data-testid="add-skill-name"]').text()).toContain('my-skill')
    expect(wrapper.text()).not.toContain('Path:')
    expect(wrapper.text()).not.toContain('SKILL.MD')
  })

  it('takes the name from skill_name when `name` is missing', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: { skill_name: 'renamed-skill', created: true },
        parameters: '{"name":"renamed-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('primary')).toBe('renamed-skill')
    expect(wrapper.find('[data-testid="add-skill-name"]').text()).toContain('renamed-skill')
  })

  it('is not expandable when a clean success carries neither a name nor args', () => {
    // Otherwise the expanded body would be an empty panel with no way to tell what happened.
    const wrapper = mount(AddSkill, {
      props: { content: { created: true } } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(false)
  })

  it('shows the error and is expandable on a refusal', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: { skill_name: 'my-skill', created: false, error: 'a skill named my-skill exists' },
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(ToolCardHeader).props('expandable')).toBe(true)
    expect(wrapper.text()).toContain('a skill named my-skill exists')
  })

  it('renders the name off a payload that still carries the retired path', () => {
    const wrapper = mount(AddSkill, {
      props: {
        content: { ...created, path: '/skills/my-skill/SKILL.MD' },
        parameters: '{"name":"my-skill"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).not.toContain('/skills/my-skill/SKILL.MD')
  })
})

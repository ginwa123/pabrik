/** SkillAutoImproveToggle.vue — the lock checkbox. Three behaviours only this component can get
 * wrong: 1. It must send the FLAG ALONE. The panel's other saves carry description + content, and a
 * toggle that posted those would race an in-flight edit. 2. */
import { mount, flushPromises } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import SkillAutoImproveToggle from '../SkillAutoImproveToggle.vue'

const { updateSkillMock } = vi.hoisted(() => ({ updateSkillMock: vi.fn() }))

vi.mock('../../../api', async () => {
  const actual = await vi.importActual<typeof import('../../../api')>('../../../api')
  return { ...actual, updateSkill: updateSkillMock }
})

function skill(isCanAutoImprove: boolean) {
  return {
    skill: {
      name: 'pdf',
      description: 'convert PDFs',
      content: '# pdf',
      asset_count: 0,
      is_can_auto_improve: isCanAutoImprove,
    },
  }
}

function mountToggle(checked: boolean) {
  return mount(SkillAutoImproveToggle, {
    props: { workspaceId: 'ws_1', skillName: 'pdf', checked },
  })
}

const box = (wrapper: ReturnType<typeof mount>) =>
  wrapper.find('[data-testid="skill-auto-improve-toggle"]').element as HTMLInputElement

beforeEach(() => {
  updateSkillMock.mockReset()
})

describe('SkillAutoImproveToggle', () => {
  it('unchecking a skill patches the flag alone and reports the new state', async () => {
    updateSkillMock.mockResolvedValue(skill(false))
    const wrapper = mountToggle(true)
    expect(box(wrapper).checked).toBe(true)

    await wrapper.find('[data-testid="skill-auto-improve-toggle"]').setValue(false)
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledTimes(1)
    expect(updateSkillMock).toHaveBeenCalledWith('ws_1', 'pdf', { is_can_auto_improve: false })
    expect(wrapper.emitted('changed')).toEqual([[false]])
    expect(wrapper.emitted('error')).toBeUndefined()
  })

  it('re-checking patches true, so a pinned skill can be handed back to the agent', async () => {
    updateSkillMock.mockResolvedValue(skill(true))
    const wrapper = mountToggle(false)

    await wrapper.find('[data-testid="skill-auto-improve-toggle"]').setValue(true)
    await flushPromises()

    expect(updateSkillMock).toHaveBeenCalledWith('ws_1', 'pdf', { is_can_auto_improve: true })
    expect(wrapper.emitted('changed')).toEqual([[true]])
  })

  it('a refused toggle snaps the checkbox back and reports why', async () => {
    updateSkillMock.mockRejectedValue(new Error('HTTP 404 skill not found'))
    const wrapper = mountToggle(true)

    await wrapper.find('[data-testid="skill-auto-improve-toggle"]').setValue(false)
    await flushPromises()

    const reported = wrapper.emitted('error')
    expect(reported).toHaveLength(1)
    expect(String(reported?.[0]?.[0])).toContain('HTTP 404 skill not found')
    expect(wrapper.emitted('changed')).toBeUndefined()
    expect(box(wrapper).checked).toBe(true)
  })

  it('renders the stored state, unchecked for a pinned skill', async () => {
    const wrapper = mountToggle(false)
    expect(box(wrapper).checked).toBe(false)
    expect(updateSkillMock).not.toHaveBeenCalled()
  })
})

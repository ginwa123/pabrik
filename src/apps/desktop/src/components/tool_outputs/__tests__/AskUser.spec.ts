/** AskUser.vue — the question card a message with an `ask_user` block draws. It renders the
 * parsed question and, while pending, POSTs the answer keyed by the message it came from. */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AskUser from '../AskUser.vue'
import { type AskUserQuestion } from '../../../helpers/askUserBlock'

vi.mock('../../../api', () => ({
  answerAskUser: vi.fn(),
}))

import { answerAskUser } from '../../../api'

const mockedAnswer = vi.mocked(answerAskUser)

function question(overrides: Partial<AskUserQuestion> = {}): AskUserQuestion {
  return {
    status: 'pending',
    rawStatus: '',
    question: 'Which environment should I deploy to?',
    header: 'Deploy target',
    options: ['staging', 'production'],
    allowFreeText: true,
    multiSelect: false,
    recommended: 'staging',
    answer: '',
    answersCount: 0,
    ...overrides,
  }
}

function mountCard(q: AskUserQuestion = question(), props: Record<string, unknown> = {}) {
  return mount(AskUser, {
    props: { question: q, messageId: 'msg_1', sessionId: 'sess_1', ...props },
  })
}

beforeEach(() => {
  mockedAnswer.mockReset()
  mockedAnswer.mockResolvedValue({ success: true, status: 'answered' } as never)
})

describe('AskUser — rendering', () => {
  it('renders the pending question with its options and the recommended chip', () => {
    const wrapper = mountCard()

    expect(wrapper.attributes('data-state')).toBe('pending')
    expect(wrapper.text()).toContain('Which environment should I deploy to?')
    expect(wrapper.text()).toContain('staging')
    expect(wrapper.text()).toContain('production')
    expect(wrapper.text()).toContain('recommended')
    expect(wrapper.text()).toContain('waiting for you')
  })

  it('carries the header as the card title', () => {
    const wrapper = mountCard()
    expect(wrapper.get('[data-testid="ask-user-header"]').text()).toContain('Deploy target')
  })

  it('falls back to the truncated question when no header was written', () => {
    const wrapper = mountCard(question({ header: '' }))
    expect(wrapper.get('[data-testid="ask-user-header"]').text()).toContain(
      'Which environment should I deploy to?',
    )
  })

  it('hides the free-text box when the model disallowed it', () => {
    const wrapper = mountCard(question({ allowFreeText: false }))
    expect(wrapper.find('[data-testid="ask-user-freetext"]').exists()).toBe(false)
  })

  it('renders a free-text-only question with no option list', () => {
    const wrapper = mountCard(question({ options: [], recommended: '' }))
    expect(wrapper.find('[data-testid="ask-user-option-0"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="ask-user-freetext"]').exists()).toBe(true)
  })

  it('renders an answered question as a resolved chip', () => {
    const wrapper = mountCard(
      question({ status: 'answered', answer: 'staging', answersCount: 1 }),
    )
    expect(wrapper.attributes('data-state')).toBe('answered')
    expect(wrapper.get('[data-testid="ask-user-resolved-summary"]').text()).toContain('staging')
    expect(wrapper.find('[data-testid="ask-user-send"]').exists()).toBe(false)
  })

  it('renders a multi-select answer as one chip with every value', () => {
    const wrapper = mountCard(
      question({ status: 'answered', answer: '["staging","production"]', answersCount: 2 }),
    )
    const text = wrapper.get('[data-testid="ask-user-resolved-summary"]').text()
    expect(text).toContain('staging')
    expect(text).toContain('production')
    expect(wrapper.get('[data-testid="ask-user-header"]').text()).toContain('2 answers')
  })

  it('distinguishes skipped from abandoned', () => {
    const skipped = mountCard(question({ status: 'skipped' }))
    expect(skipped.get('[data-testid="ask-user-resolved-summary"]').text()).toContain('skipped')
    skipped.unmount()

    const abandoned = mountCard(question({ status: 'abandoned' }))
    expect(abandoned.get('[data-testid="ask-user-resolved-summary"]').text()).toContain('moved on')
  })

  it('shows a status this build does not know as settled, never interactive', () => {
    const wrapper = mountCard(question({ status: 'settled', rawStatus: 'unavailable' }))
    expect(wrapper.attributes('data-state')).toBe('settled')
    expect(wrapper.get('[data-testid="ask-user-settled"]').text()).toContain('unavailable')
    expect(wrapper.find('[data-testid="ask-user-send"]').exists()).toBe(false)
  })

  it('renders <>& in the question verbatim', () => {
    const wrapper = mountCard(question({ question: 'Is <a> & <b> fine?' }))
    expect(wrapper.get('[data-testid="ask-user-question"]').text()).toContain(
      'Is <a> & <b> fine?',
    )
  })
})

describe('AskUser — markdown', () => {
  it('renders the markdown the model writes instead of its syntax', () => {
    const wrapper = mountCard(question({ question: 'Pick **one** of these:' }))
    const host = wrapper.get('[data-testid="ask-user-question"]')
    expect(host.html()).toContain('<strong>one</strong>')
    expect(host.classes()).toContain('markdown-content')
  })

  it('strips markdown out of the option label but POSTs the raw option', async () => {
    const wrapper = mountCard(question({ options: ['**staging**', 'production'] }))
    expect(wrapper.get('[data-testid="ask-user-option-0"]').text()).toContain('staging')
    expect(wrapper.get('[data-testid="ask-user-option-0"]').text()).not.toContain('**')

    await wrapper.get('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')
    expect(mockedAnswer).toHaveBeenCalledWith(
      'sess_1',
      expect.objectContaining({ answer: '**staging**' }),
    )
  })

  it('strips markdown out of the resolved answer chip', () => {
    const wrapper = mountCard(question({ status: 'answered', answer: '**staging**' }))
    const text = wrapper.get('[data-testid="ask-user-resolved-summary"]').text()
    expect(text).toContain('staging')
    expect(text).not.toContain('**')
  })
})

describe('AskUser — the wire body', () => {
  it('POSTs the message id and the picked option for a single-select question', async () => {
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      message_id: 'msg_1',
      answer: 'staging',
    })
  })

  it('POSTs a JSON array for a multi-select question', async () => {
    const wrapper = mountCard(question({ multiSelect: true }))
    await wrapper.get('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-option-1"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      message_id: 'msg_1',
      answer: '["staging","production"]',
    })
  })

  it('POSTs the typed free text when the user typed instead of picking', async () => {
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-freetext"]').setValue('  eu-west-1  ')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      message_id: 'msg_1',
      answer: 'eu-west-1',
    })
  })

  it('POSTs skip:true and no answer for Skip', async () => {
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-skip"]').trigger('click')

    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', { message_id: 'msg_1', skip: true })
  })

  it('does not POST while nothing is selected', async () => {
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')
    expect(mockedAnswer).not.toHaveBeenCalled()
  })

  it('flips the card locally once the POST succeeds', async () => {
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-option-0"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')
    await nextTick()

    expect(wrapper.attributes('data-state')).toBe('answered')
  })

  it('shows a Retry affordance when the POST fails and keeps the selection', async () => {
    mockedAnswer.mockResolvedValue({ success: false } as never)
    const wrapper = mountCard()
    await wrapper.get('[data-testid="ask-user-option-1"]').trigger('click')
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')
    await nextTick()

    expect(wrapper.find('[data-testid="ask-user-error"]').exists()).toBe(true)
    await wrapper.get('[data-testid="ask-user-send"]').trigger('click')
    expect(mockedAnswer).toHaveBeenLastCalledWith('sess_1', {
      message_id: 'msg_1',
      answer: 'production',
    })
  })

  it('each card posts the message it was drawn under', async () => {
    const first = mountCard(question(), { messageId: 'msg_a' })
    const second = mountCard(question(), { messageId: 'msg_b' })

    await first.get('[data-testid="ask-user-option-0"]').trigger('click')
    await first.get('[data-testid="ask-user-send"]').trigger('click')
    await second.get('[data-testid="ask-user-option-1"]').trigger('click')
    await second.get('[data-testid="ask-user-send"]').trigger('click')

    expect(mockedAnswer).toHaveBeenNthCalledWith(1, 'sess_1', {
      message_id: 'msg_a',
      answer: 'staging',
    })
    expect(mockedAnswer).toHaveBeenNthCalledWith(2, 'sess_1', {
      message_id: 'msg_b',
      answer: 'production',
    })
    first.unmount()
    second.unmount()
  })
})

describe('AskUser — keyboard', () => {
  it('digits pick an option, Enter sends and Escape skips', async () => {
    const wrapper = mountCard()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '2' }))
    await nextTick()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await nextTick()
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', {
      message_id: 'msg_1',
      answer: 'production',
    })

    mockedAnswer.mockClear()
    wrapper.unmount()

    const skipping = mountCard()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', { message_id: 'msg_1', skip: true })
    skipping.unmount()
  })

  it('ignores digits beyond the option count', async () => {
    const wrapper = mountCard()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: '9' }))
    await nextTick()
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await nextTick()
    expect(mockedAnswer).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('stops listening once the question is resolved', async () => {
    const wrapper = mountCard(question({ status: 'answered', answer: 'staging' }))
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }))
    await nextTick()
    expect(mockedAnswer).not.toHaveBeenCalled()
    wrapper.unmount()
  })
})

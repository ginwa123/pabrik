/** AskUser.vue — MULTIPLE pending cards in one turn. Every existing spec in `AskUser.spec.ts`
 * mounts exactly ONE card. That is why the shared-`window`-listener design has never failed a test:
 * with one card there is nothing for a fan-out to hit. */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import AskUser from '../AskUser.vue'

vi.mock('../../../api', () => ({
  answerAskUser: vi.fn(),
}))

import { answerAskUser } from '../../../api'

const mockedAnswer = vi.mocked(answerAskUser)

function pendingData(questionId: string, question: string): Record<string, unknown> {
  return {
    status: 'pending',
    question_id: questionId,
    header: 'Deploy target',
    question,
    allow_free_text: true,
    multi_select: false,
    recommended: 'staging',
    options: ['staging', 'production'],
    instruction: 'The human has been asked.',
  }
}

function mountCard(content: unknown) {
  return mount(AskUser, {
    props: { content, parameters: '{}', expanded: true, sessionId: 'sess_1' },
  })
}

const dispatch = (key: string) =>
  window.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }))

beforeEach(() => {
  mockedAnswer.mockReset()
})

describe('AskUser — two pending cards in one turn', () => {
  it('a digit pick applies to EVERY pending card, not just the focused one', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'production' })
    const a = mountCard(pendingData('q_1', 'Which environment should I deploy to?'))
    const b = mountCard(pendingData('q_2', 'Which region should I deploy to?'))

    // One keystroke, two cards.
    dispatch('1')
    await flush()

    // Both cards now show the same pick — the human pressed one key to answer
    // a question they had not read yet.
    expect(a.text()).toContain('✓')
    expect(b.text()).toContain('✓')

    a.unmount()
    b.unmount()
  })

  it('Enter POSTs once per pending card instead of once per human intent', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'staging' })
    const a = mountCard(pendingData('q_1', 'Which environment should I deploy to?'))
    const b = mountCard(pendingData('q_2', 'Which region should I deploy to?'))

    dispatch('1')
    await flush()
    dispatch('Enter')
    await flush()

    // The bug: TWO POSTs from one keystroke. The backend resumes the run for
    // at most one of them and silently drops the delivery of the other.
    expect(mockedAnswer).toHaveBeenCalledTimes(2)
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', { question_id: 'q_1', answer: 'staging' })
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', { question_id: 'q_2', answer: 'staging' })

    a.unmount()
    b.unmount()
  })

  it('Escape skips EVERY pending card at once', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'skipped', answer: '' })
    const a = mountCard(pendingData('q_1', 'Which environment should I deploy to?'))
    const b = mountCard(pendingData('q_2', 'Which region should I deploy to?'))

    dispatch('Escape')
    await flush()

    expect(mockedAnswer).toHaveBeenCalledTimes(2)
    for (const call of mockedAnswer.mock.calls) {
      expect(call[1]).toMatchObject({ skip: true })
    }

    a.unmount()
    b.unmount()
  })

  it('resolving ONE card leaves the other pending and still holding a window listener', async () => {
    mockedAnswer.mockResolvedValue({ success: true, status: 'answered', answer: 'staging' })
    const a = mountCard(pendingData('q_1', 'Which environment should I deploy to?'))
    const b = mountCard(pendingData('q_2', 'Which region should I deploy to?'))

    // The mouse path: pick an option on card A only, then click ITS Send.
    await a.find('[data-testid="ask-user-option-0"]').trigger('click')
    await a.find('[data-testid="ask-user-send"]').trigger('click')
    await flush()

    expect(mockedAnswer).toHaveBeenCalledTimes(1)
    expect(mockedAnswer).toHaveBeenCalledWith('sess_1', { question_id: 'q_1', answer: 'staging' })
    expect(a.attributes('data-state')).toBe('answered')
    // B is untouched and still interactive…
    expect(b.attributes('data-state')).toBe('pending')
    // …and it still owns a window listener, so the human's next keystroke
    // reaches it. Nothing in the card marks B as "the one to answer next", and
    // no endpoint tells it that A was already resolved.
    dispatch('Enter')
    await flush()
    expect(mockedAnswer).toHaveBeenCalledTimes(1)

    a.unmount()
    b.unmount()
  })
})

async function flush(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
  await new Promise((resolve) => setTimeout(resolve, 0))
}

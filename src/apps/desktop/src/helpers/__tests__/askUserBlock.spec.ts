import { describe, expect, it } from 'vitest'
import {
  parseAskUserBlock,
  stripAskUserBlock,
  stripAskUserBlockPartial,
} from '../askUserBlock'

const block = (json: string): string => `<ask_user>${json}</ask_user>`

const askJson = JSON.stringify({
  header: 'Deploy target',
  question: 'Which environment?',
  options: ['staging', 'production'],
  recommended: 'staging',
})

describe('parseAskUserBlock', () => {
  it('a message with no block yields no question', () => {
    expect(parseAskUserBlock('Which environment? Just tell me.')).toBeNull()
    expect(parseAskUserBlock('')).toBeNull()
    expect(parseAskUserBlock(undefined)).toBeNull()
  })

  it('a trailing block yields the question it describes', () => {
    const q = parseAskUserBlock(`One thing first.\n${block(askJson)}`)
    expect(q).not.toBeNull()
    expect(q?.question).toBe('Which environment?')
    expect(q?.header).toBe('Deploy target')
    expect(q?.options).toEqual(['staging', 'production'])
    expect(q?.recommended).toBe('staging')
    expect(q?.status).toBe('pending')
    expect(q?.multiSelect).toBe(false)
    expect(q?.allowFreeText).toBe(true)
  })

  it('a block that is not JSON yields no question', () => {
    expect(parseAskUserBlock(block('not json'))).toBeNull()
    expect(parseAskUserBlock(block('{'))).toBeNull()
  })

  it('a block without a question yields no question', () => {
    expect(parseAskUserBlock(block(JSON.stringify({ options: ['a', 'b'] })))).toBeNull()
    expect(parseAskUserBlock(block(JSON.stringify({ question: '   ' })))).toBeNull()
  })

  it('only the last block of a message is honoured', () => {
    const q = parseAskUserBlock(
      `${block(JSON.stringify({ question: 'first' }))}\n${block(JSON.stringify({ question: 'second' }))}`,
    )
    expect(q?.question).toBe('second')
  })

  it('an answered block reports the answer it carries', () => {
    const q = parseAskUserBlock(
      block(JSON.stringify({ question: 'Which environment?', status: 'answered', answer: 'staging', answers_count: 1 })),
    )
    expect(q?.status).toBe('answered')
    expect(q?.answer).toBe('staging')
    expect(q?.answersCount).toBe(1)
  })

  it('an unknown status is settled, never interactive', () => {
    const q = parseAskUserBlock(block(JSON.stringify({ question: 'q', status: 'unavailable' })))
    expect(q?.status).toBe('settled')
    expect(q?.rawStatus).toBe('unavailable')
  })

  it('a question containing the closing marker still parses', () => {
    const q = parseAskUserBlock(block(JSON.stringify({ question: 'Is </ask_user> fine?' })))
    expect(q?.question).toBe('Is </ask_user> fine?')
  })
})

describe('stripAskUserBlock', () => {
  it('the block is removed and the prose kept', () => {
    expect(stripAskUserBlock(`Before.\n${block(askJson)}\nAfter.`)).toBe('Before.\n\nAfter.')
  })

  it('a message that is only a block strips to nothing', () => {
    expect(stripAskUserBlock(block(askJson))).toBe('')
  })

  it('a message with no block is unchanged', () => {
    expect(stripAskUserBlock('Just an answer.  ')).toBe('Just an answer.')
  })
})

describe('stripAskUserBlockPartial', () => {
  it('a marker the stream has not finished writing is not shown', () => {
    expect(stripAskUserBlockPartial('One thing first.\n<ask_us')).toBe('One thing first.')
    expect(stripAskUserBlockPartial('One thing first.\n<')).toBe('One thing first.')
  })

  it('an open marker with no close yet is not shown', () => {
    expect(stripAskUserBlockPartial('One thing first.\n<ask_user>{"question":"W')).toBe(
      'One thing first.',
    )
  })

  it('a complete block is stripped like the settled case', () => {
    expect(stripAskUserBlockPartial(`Before.\n${block(askJson)}`)).toBe('Before.')
  })
})

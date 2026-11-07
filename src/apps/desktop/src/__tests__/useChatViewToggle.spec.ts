/** The grouped/raw view toggle: its labels, its flip, and the config mapping. */
import { beforeEach, describe, expect, it } from 'vitest'
import { useChatViewToggle } from '../composables/useChatViewToggle'
import { chatViewModeFrom, setChatViewMode } from '../stores/chatView'

describe('useChatViewToggle', () => {
  beforeEach(() => setChatViewMode('dev'))

  it('starts grouped and flips to raw and back', () => {
    const { isRaw, label, nextLabel, toggle } = useChatViewToggle()
    expect(isRaw.value).toBe(false)
    expect(label.value).toBe('Grouped')
    expect(nextLabel.value).toBe('Rows')

    toggle()
    expect(isRaw.value).toBe(true)
    expect(label.value).toBe('Rows')
    expect(nextLabel.value).toBe('Grouped')

    toggle()
    expect(isRaw.value).toBe(false)
  })

  it('maps the persisted config value, and anything unknown back to dev', () => {
    expect(chatViewModeFrom({ chat_view: 'raw' })).toBe('raw')
    expect(chatViewModeFrom({ chat_view: 'compact' })).toBe('compact')
    expect(chatViewModeFrom({ chat_view: 'nonsense' })).toBe('dev')
    expect(chatViewModeFrom({})).toBe('dev')
    expect(chatViewModeFrom(null)).toBe('dev')
  })
})

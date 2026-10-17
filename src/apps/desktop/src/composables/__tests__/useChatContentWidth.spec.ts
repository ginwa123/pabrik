/** Transcript width preference: the default, the click order and persistence. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { CHAT_CONTENT_WIDTH_STORAGE_KEY, useChatContentWidth } from '../useChatContentWidth'
import { makeLocalStorageStub } from '../../__tests__/helpers'

describe('useChatContentWidth', () => {
  const { width, presetClass, label, nextLabel, setWidth, cycleWidth } = useChatContentWidth()

  beforeEach(() => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    setWidth('full')
  })

  it('defaults to full — no stored preference means no side gutters', () => {
    expect(width.value).toBe('full')
    expect(presetClass.value).toBe('')
    expect(label.value).toBe('Full')
  })

  it('cycles full → comfortable → wide → full', () => {
    cycleWidth()
    expect(width.value).toBe('comfortable')
    cycleWidth()
    expect(width.value).toBe('wide')
    cycleWidth()
    expect(width.value).toBe('full')
  })

  it('names the preset it would move to, so the button can say so', () => {
    expect(nextLabel.value).toBe('Comfortable')
    setWidth('comfortable')
    expect(nextLabel.value).toBe('Wide')
    expect(label.value).toBe('Comfortable')
    expect(presetClass.value).toBe('chat-width-comfortable')
  })

  it('remembers the choice, so a reload does not undo it', () => {
    setWidth('wide')
    expect(globalThis.localStorage.getItem(CHAT_CONTENT_WIDTH_STORAGE_KEY)).toBe('wide')
    expect(presetClass.value).toBe('chat-width-wide')
  })

  it('restores a stored preset on a fresh load', async () => {
    globalThis.localStorage.setItem(CHAT_CONTENT_WIDTH_STORAGE_KEY, 'comfortable')
    vi.resetModules()
    const fresh = await import('../useChatContentWidth')
    expect(fresh.useChatContentWidth().width.value).toBe('comfortable')
  })

  it('falls back to full for a stored value that is not a preset', async () => {
    globalThis.localStorage.setItem(CHAT_CONTENT_WIDTH_STORAGE_KEY, 'gigantic')
    vi.resetModules()
    const fresh = await import('../useChatContentWidth')
    expect(fresh.useChatContentWidth().width.value).toBe('full')
  })
})

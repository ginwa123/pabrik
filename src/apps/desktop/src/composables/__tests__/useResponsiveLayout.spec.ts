import { describe, it, expect } from 'vitest'
import { effectScope } from 'vue'
import { MOBILE_QUERY, useResponsiveLayout } from '../useResponsiveLayout'

class FakeMediaQueries {
  matches = false
  queries: string[] = []
  private listeners = new Set<(matches: boolean) => void>()

  matchesQuery(query: string): boolean {
    this.queries.push(query)
    return this.matches
  }

  subscribe(query: string, listener: (matches: boolean) => void): () => void {
    this.queries.push(query)
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  change(matches: boolean): void {
    this.matches = matches
    const listeners = Array.from(this.listeners)
    for (const listener of listeners) listener(matches)
  }

  get listenerCount(): number {
    return this.listeners.size
  }
}

function mountLayout(media: FakeMediaQueries) {
  const scope = effectScope()
  const layout = scope.run(() => useResponsiveLayout(media))
  if (!layout) throw new Error('useResponsiveLayout did not run')
  return { scope, isMobile: layout.isMobile }
}

describe('useResponsiveLayout', () => {
  it('reports a narrow viewport as mobile', () => {
    const media = new FakeMediaQueries()
    media.matches = true
    const { isMobile } = mountLayout(media)
    expect(isMobile.value).toBe(true)
  })

  it('reports a wide viewport as desktop', () => {
    const media = new FakeMediaQueries()
    const { isMobile } = mountLayout(media)
    expect(isMobile.value).toBe(false)
  })

  it('watches the mobile breakpoint, not some other width', () => {
    const media = new FakeMediaQueries()
    mountLayout(media)
    expect(media.queries).toContain(MOBILE_QUERY)
  })

  it('follows the viewport from desktop into mobile', () => {
    const media = new FakeMediaQueries()
    const { isMobile } = mountLayout(media)
    media.change(true)
    expect(isMobile.value).toBe(true)
  })

  it('follows the viewport from mobile back into desktop', () => {
    const media = new FakeMediaQueries()
    media.matches = true
    const { isMobile } = mountLayout(media)
    media.change(false)
    expect(isMobile.value).toBe(false)
  })

  it('stops listening once its scope is disposed', () => {
    const media = new FakeMediaQueries()
    const { scope, isMobile } = mountLayout(media)
    scope.stop()
    expect(media.listenerCount).toBe(0)
    media.change(true)
    expect(isMobile.value).toBe(false)
  })
})

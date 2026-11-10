/** `downloadBlob` is the one place the app hands bytes to the browser's download path: the
 * anchor must carry the server's filename, and the object URL must be released rather than
 * leaked one per export. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { downloadBlob } from '../helpers/download'

describe('downloadBlob', () => {
  let created: string[]
  let revoked: string[]
  let clicked: HTMLAnchorElement[]

  beforeEach(() => {
    // Fake timers keep the deferred revoke inside the test that scheduled it —
    // a real timer from an earlier test would land in this test's `revoked`.
    vi.useFakeTimers()
    created = []
    revoked = []
    clicked = []
    let n = 0
    vi.spyOn(URL, 'createObjectURL').mockImplementation(() => {
      const url = `blob:mock-${++n}`
      created.push(url)
      return url
    })
    vi.spyOn(URL, 'revokeObjectURL').mockImplementation((url: string) => {
      revoked.push(url)
    })
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      clicked.push(this)
    })
  })

  afterEach(() => {
    vi.runOnlyPendingTimers()
    vi.useRealTimers()
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('clicks an anchor that carries the filename the server chose', () => {
    downloadBlob(new Blob(['# plan']), 'Release plan.md')

    expect(clicked).toHaveLength(1)
    expect(clicked[0]?.download).toBe('Release plan.md')
    expect(clicked[0]?.href).toBe('blob:mock-1')
  })

  it('leaves no anchor behind in the document', () => {
    downloadBlob(new Blob(['x']), 'a.md')
    expect(document.querySelectorAll('a')).toHaveLength(0)
  })

  it('releases the object URL instead of leaking one per export', () => {
    downloadBlob(new Blob(['x']), 'a.md')
    downloadBlob(new Blob(['y']), 'b.md')

    expect(created).toHaveLength(2)
    // Revocation is deferred one task so the download is not cancelled.
    expect(revoked).toEqual([])
    vi.runAllTimers()
    expect(revoked).toEqual(created)
  })
})

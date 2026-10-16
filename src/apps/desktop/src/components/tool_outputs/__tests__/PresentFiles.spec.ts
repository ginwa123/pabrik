/** Tests for PresentFiles.vue — the tool-output card component for the `present_files` agent tool. */
import { flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import PresentFiles from '../PresentFiles.vue'
import { FRAME_CANVAS_FALLBACK } from '@/helpers'
import { _resetMermaidLoader } from '@/helpers/mermaid'

// A presented mermaid file renders through <MermaidDiagram>; mermaid itself
// is mocked because jsdom has no layout.
const { initializeMock, renderMock } = vi.hoisted(() => ({
  initializeMock: vi.fn(),
  renderMock: vi.fn(),
}))

vi.mock('mermaid', () => ({ default: { initialize: initializeMock, render: renderMock } }))

const MERMAID_SOURCE = 'flowchart TD\n  A[Prompt] --> B[Diagram]'

// The html/pdf/text branches fetch source over same-origin `fetch` —
// stub it so no test performs a real network call and previews resolve
// deterministically.
const fetchMock = vi.fn()
const origCreateObjectURL = URL.createObjectURL
const origRevokeObjectURL = URL.revokeObjectURL

beforeEach(() => {
  fetchMock.mockImplementation(
    async () =>
      ({
        ok: true,
        status: 200,
        text: async () => '<h1>Hello</h1>',
        blob: async () => new Blob(['%PDF-mock'], { type: 'application/pdf' }),
      }) as Response,
  )
  vi.stubGlobal('fetch', fetchMock)
  _resetMermaidLoader()
  initializeMock.mockClear()
  renderMock.mockReset()
  renderMock.mockResolvedValue({ svg: '<svg data-rendered="yes"></svg>' })
  URL.createObjectURL = vi.fn(() => 'blob:mock-preview') as unknown as typeof URL.createObjectURL
  URL.revokeObjectURL = vi.fn() as unknown as typeof URL.revokeObjectURL
})

afterEach(() => {
  vi.unstubAllGlobals()
  URL.createObjectURL = origCreateObjectURL
  URL.revokeObjectURL = origRevokeObjectURL
})

// ─── Test helpers ──────────────────────────────────────────────────────────
const makeSuccessContent = () => ({
  status: 'presented',
  count: 2,
  files: [
    { path: '/tmp/notes.txt', bytes: 11, mime: 'text/plain; charset=utf-8', label: 'notes' },
    { path: '/tmp/photo.jpg', bytes: 48211, mime: 'image/jpeg', label: 'photo.jpg' },
  ],
})

const makeErrorContent = (
  msg = 'present_files: file not found (or is a directory): "/tmp/nope.txt".',
) => ({ status: null, count: 0, files: [], error: msg })

const mountCard = (content: unknown, sessionId = 'sess_123', expanded = true) =>
  mount(PresentFiles, { props: { content, sessionId, expanded } as never })

// ─── Tests ─────────────────────────────────────────────────────────────────
describe('PresentFiles', () => {
  it('renders the card with a data-testid', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.find('[data-testid="present-files-card"]').exists()).toBe(true)
  })

  it('success path: header shows count + ✓', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.text()).toContain('present_files')
    expect(wrapper.text()).toContain('2 files')
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('renders one row per file with label, size and mime', () => {
    const wrapper = mountCard(makeSuccessContent())
    expect(wrapper.find('[data-testid="present-files-row-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="present-files-row-1"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('notes')
    expect(wrapper.text()).toContain('photo.jpg')
    expect(wrapper.text()).toContain('11 B')
    expect(wrapper.text()).toContain('47.1 KB')
    expect(wrapper.text()).toContain('image/jpeg')
  })

  it('download anchors point at /api/files/download with disposition=attachment', () => {
    const wrapper = mountCard(makeSuccessContent())
    const dl = wrapper.find('[data-testid="present-files-download-0"]').attributes('href') ?? ''
    expect(dl).toContain('/api/files/download')
    expect(dl).toContain('session_id=sess_123')
    expect(dl).toContain(`path=${encodeURIComponent('/tmp/notes.txt')}`)
    expect(dl).toContain('disposition=attachment')
    const btn = wrapper.find('[data-testid="present-files-dlbtn-1"]').attributes('href') ?? ''
    expect(btn).toContain('disposition=attachment')
    expect(btn).toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
  })

  it('image files render an inline thumbnail; text files do not', () => {
    const wrapper = mountCard(makeSuccessContent())
    const thumb = wrapper.find('[data-testid="present-files-thumb-1"]')
    expect(thumb.exists()).toBe(true)
    expect(thumb.attributes('src') ?? '').toContain('disposition=inline')
    expect(thumb.attributes('src') ?? '').toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
    expect(wrapper.find('[data-testid="present-files-thumb-0"]').exists()).toBe(false)
  })

  it('error path: red border + ✗ + error message inline', () => {
    const wrapper = mountCard(makeErrorContent())
    expect(wrapper.find('[data-testid="present-files-card"]').classes()).toContain(
      'border-red-500/50',
    )
    expect(wrapper.text()).toContain('✗')
    expect(wrapper.text()).toContain('file not found')
  })

  it('rows are hidden until expanded', () => {
    const wrapper = mountCard(makeSuccessContent(), 'sess_123', false)
    expect(wrapper.find('[data-testid="present-files-row-0"]').exists()).toBe(false)
  })

  it('expanded by default: rows render with no expanded prop', () => {
    const wrapper = mount(PresentFiles, {
      props: { content: makeSuccessContent(), sessionId: 'sess_123' } as never,
    })
    expect(wrapper.find('[data-testid="present-files-row-0"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="present-files-row-1"]').exists()).toBe(true)
  })

  it('html/pdf preview chrome uses the dark card bg, not bg-white', async () => {
    const html = mountCard({
      status: 'presented',
      count: 1,
      files: [
        { path: '/tmp/a.html', bytes: 10, mime: 'text/html; charset=utf-8', label: 'a.html' },
      ],
    })
    await flushPromises()
    const htmlBox = html.find('[data-testid="present-files-inline-html-0"]')
    expect(htmlBox.exists()).toBe(true)
    expect(htmlBox.classes().join(' ')).not.toContain('bg-white')
    const pdf = mountCard({
      status: 'presented',
      count: 1,
      files: [{ path: '/tmp/d.pdf', bytes: 10, mime: 'application/pdf', label: 'd.pdf' }],
    })
    await flushPromises()
    const pdfBox = pdf.find('[data-testid="present-files-inline-pdf-0"]')
    expect(pdfBox.exists()).toBe(true)
    expect(pdfBox.classes().join(' ')).not.toContain('bg-white')
  })

  it('html preview srcdoc paints the frame canvas, never a hardcoded white', async () => {
    const wrapper = mountCard({
      status: 'presented',
      count: 1,
      files: [
        { path: '/tmp/a.html', bytes: 10, mime: 'text/html; charset=utf-8', label: 'a.html' },
      ],
    })
    await flushPromises()
    const frame = wrapper.find('[data-testid="present-files-inline-html-0"] iframe')
    expect(frame.exists()).toBe(true)
    const srcdoc = frame.attributes('srcdoc') ?? ''
    // The injected shell also styles `html`: a hardcoded #fff canvas shows through as a white slab
    // wherever the presented document's own `body` box does not cover it.
    expect(srcdoc).not.toMatch(/background:\s*#fff/i)
    expect(srcdoc.toLowerCase()).toContain(`background:${FRAME_CANVAS_FALLBACK}`)
  })

  it('image files render a full-width inline preview (click → fullscreen)', () => {
    const wrapper = mountCard(makeSuccessContent())
    const inline = wrapper.find('[data-testid="present-files-inline-image-1"]')
    expect(inline.exists()).toBe(true)
    expect(inline.attributes('src') ?? '').toContain('disposition=inline')
    expect(inline.attributes('src') ?? '').toContain(`path=${encodeURIComponent('/tmp/photo.jpg')}`)
  })

  it('html files render fetched source in a sandboxed srcdoc iframe (no src navigation)', async () => {
    const content = {
      status: 'presented',
      count: 1,
      files: [
        {
          path: '/tmp/test-page.html',
          bytes: 655,
          mime: 'text/html; charset=utf-8',
          label: 'test-page.html',
        },
      ],
    }
    const wrapper = mountCard(content)
    await flushPromises()
    const frame = wrapper.find('[data-testid="present-files-inline-html-0"] iframe')
    expect(frame.exists()).toBe(true)
    // Direct src navigation is refused by the server's framing headers
    // (X-Frame-Options: DENY + frame-ancestors 'none'), so the iframe
    // must use srcdoc with the fetched bytes — never a download URL.
    expect(frame.attributes('src') ?? '').toBe('')
    const srcdoc = frame.attributes('srcdoc') ?? ''
    expect(srcdoc).toContain('<h1>Hello</h1>')
    expect(frame.attributes('sandbox') ?? '').toContain('allow-scripts')
    expect(frame.attributes('sandbox') ?? '').not.toContain('allow-same-origin')
    expect(wrapper.find('[data-testid="present-files-open-tab-0"]').exists()).toBe(true)
    // The bytes arrive via same-origin fetch (cookies ride along).
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining(`path=${encodeURIComponent('/tmp/test-page.html')}`),
    )
  })

  it('oversize html files skip the inline preview but keep open-in-new-tab', async () => {
    const content = {
      status: 'presented',
      count: 1,
      files: [
        {
          path: '/tmp/big.html',
          bytes: 2097152,
          mime: 'text/html; charset=utf-8',
          label: 'big.html',
        },
      ],
    }
    const wrapper = mountCard(content)
    await flushPromises()
    expect(wrapper.find('[data-testid="present-files-inline-html-0"] iframe').exists()).toBe(false)
    expect(wrapper.find('[data-testid="present-files-inline-html-0"]').text()).toContain(
      'too large for inline HTML preview',
    )
    expect(wrapper.find('[data-testid="present-files-open-tab-0"]').exists()).toBe(true)
  })

  it('html fetch failure shows an error with the open-in-new-tab fallback', async () => {
    fetchMock.mockImplementationOnce(async () => ({ ok: false, status: 403 }) as Response)
    const content = {
      status: 'presented',
      count: 1,
      files: [
        { path: '/tmp/gone.html', bytes: 10, mime: 'text/html; charset=utf-8', label: 'gone.html' },
      ],
    }
    const wrapper = mountCard(content)
    await flushPromises()
    expect(wrapper.find('[data-testid="present-files-inline-html-0"] iframe').exists()).toBe(false)
    expect(wrapper.find('[data-testid="present-files-inline-html-0"]').text()).toContain(
      'Preview failed to load',
    )
    expect(wrapper.find('[data-testid="present-files-open-tab-0"]').exists()).toBe(true)
  })

  it('pdf files render a fetched blob object URL (no src navigation) + open-in-new-tab', async () => {
    const content = {
      status: 'presented',
      count: 1,
      files: [{ path: '/tmp/doc.pdf', bytes: 100, mime: 'application/pdf', label: 'doc.pdf' }],
    }
    const wrapper = mountCard(content)
    await flushPromises()
    const pdf = wrapper.find('[data-testid="present-files-inline-pdf-0"] iframe')
    expect(pdf.exists()).toBe(true)
    // Same framing-header reason as html: the blob URL carries no
    // server framing headers, so it embeds where src navigation can't.
    expect(pdf.attributes('src') ?? '').toBe('blob:mock-preview')
    expect(URL.createObjectURL).toHaveBeenCalled()
    expect(wrapper.find('[data-testid="present-files-open-tab-0"]').exists()).toBe(true)
  })

  it('video / audio files render native inline players', () => {
    const content = {
      status: 'presented',
      count: 2,
      files: [
        { path: '/tmp/clip.mp4', bytes: 200, mime: 'video/mp4', label: 'clip.mp4' },
        { path: '/tmp/song.mp3', bytes: 300, mime: 'audio/mpeg', label: 'song.mp3' },
      ],
    }
    const wrapper = mountCard(content)
    const video = wrapper.find('[data-testid="present-files-inline-video-0"] video')
    expect(video.exists()).toBe(true)
    expect(video.attributes('src') ?? '').toContain('disposition=inline')
    const audio = wrapper.find('[data-testid="present-files-inline-audio-1"] audio')
    expect(audio.exists()).toBe(true)
    expect(audio.attributes('src') ?? '').toContain('disposition=inline')
  })

  it('markdown files render fetched source via the shared renderer', async () => {
    const content = {
      status: 'presented',
      count: 1,
      files: [
        {
          path: '/tmp/readme.md',
          bytes: 7,
          mime: 'text/markdown; charset=utf-8',
          label: 'readme.md',
        },
      ],
    }
    const wrapper = mountCard(content)
    await flushPromises()
    expect(wrapper.find('[data-testid="present-files-inline-text-0"]').exists()).toBe(true)
    // The stubbed fetch returns '<h1>Hello</h1>' → <h1> via marked().
    expect(wrapper.find('[data-testid="present-files-inline-text-0"]').html()).toContain('<h1')
  })

  it('mermaid files (.mmd) render as a diagram, not as their own source text', async () => {
    // `application/octet-stream` is what a server guesses for `.mmd`: the
    // extension, not the mime, is what identifies a mermaid file.
    fetchMock.mockImplementationOnce(
      async () => ({ ok: true, status: 200, text: async () => MERMAID_SOURCE }) as Response,
    )
    const wrapper = mountCard({
      status: 'presented',
      count: 1,
      files: [
        {
          path: '/tmp/flow.mmd',
          bytes: 26,
          mime: 'application/octet-stream',
          label: 'flow.mmd',
        },
      ],
    })
    await flushPromises()

    const inline = wrapper.find('[data-testid="present-files-inline-text-0"]')
    expect(inline.exists()).toBe(true)
    expect(inline.find('[data-testid="preview-mermaid"]').exists()).toBe(true)
    expect(renderMock.mock.calls[0]?.[1]).toBe(MERMAID_SOURCE)
  })
})

/** Loading-space reserves (scroll pop-in fix). Text/html/pdf/image previews resolve asynchronously
 * AFTER the card mounts. Without reserved space the card mounts small and pops taller when the
 * fetch/decode lands — mid-scroll, that reads as "content suddenly shows up". */
describe('PresentFiles loading reserves', () => {
  const pendingFetch = () => new Promise<Response>(() => {})

  it('text loading shows a reserved skeleton block', async () => {
    fetchMock.mockImplementation(pendingFetch)
    const wrapper = mountCard({
      status: 'presented',
      count: 1,
      files: [
        { path: '/tmp/notes.txt', bytes: 11, mime: 'text/plain; charset=utf-8', label: 'notes' },
      ],
    })
    await flushPromises()
    const inline = wrapper.find('[data-testid="present-files-inline-text-0"]')
    expect(inline.exists()).toBe(true)
    expect(inline.text()).toContain('Loading preview')
    const skeleton = inline.find('[aria-hidden="true"]')
    expect(skeleton.exists()).toBe(true)
    expect(skeleton.classes()).toContain('min-h-32')
  })

  it('html loading reserves the ready iframe minimum height', async () => {
    fetchMock.mockImplementation(pendingFetch)
    const wrapper = mountCard({
      status: 'presented',
      count: 1,
      files: [
        {
          path: '/tmp/test-page.html',
          bytes: 655,
          mime: 'text/html; charset=utf-8',
          label: 'test-page.html',
        },
      ],
    })
    await flushPromises()
    const box = wrapper.find(
      '[data-testid="present-files-inline-html-0"] > div:not([class*="border-t"])',
    )
    expect(box.exists()).toBe(true)
    expect(box.classes()).toContain('min-h-[200px]')
  })

  it('pdf loading reserves the ready iframe height', async () => {
    fetchMock.mockImplementation(pendingFetch)
    const wrapper = mountCard({
      status: 'presented',
      count: 1,
      files: [{ path: '/tmp/doc.pdf', bytes: 100, mime: 'application/pdf', label: 'doc.pdf' }],
    })
    await flushPromises()
    const box = wrapper.find(
      '[data-testid="present-files-inline-pdf-0"] > div:not([class*="border-t"])',
    )
    expect(box.exists()).toBe(true)
    expect(box.classes()).toContain('min-h-[480px]')
  })

  it('inline image wrapper reserves space until decode, then releases it', async () => {
    const wrapper = mountCard(makeSuccessContent())
    await flushPromises()
    const inline = wrapper.find('[data-testid="present-files-inline-image-1"]')
    expect(inline.exists()).toBe(true)
    const box = inline.element.parentElement
    expect(box?.className ?? '').toContain('min-h-40')
    await inline.trigger('load')
    expect(box?.className ?? '').not.toContain('min-h-40')
  })
})

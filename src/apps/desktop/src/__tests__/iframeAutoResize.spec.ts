import { describe, expect, it, vi } from 'vitest'

import {
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  FRAME_CANVAS_FALLBACK,
  FRAME_NO_SCROLLBAR_STYLE,
  MAX_FRAME_HEIGHT,
  MIN_FRAME_HEIGHT,
  PREVIEW_AUTO_RESIZE_SCRIPT,
  PREVIEW_AUTO_RESIZE_SOURCE,
  autoResizeScript,
  clampFrameHeight,
  findSenderFrame,
  frameDocumentStyle,
  growFrameToContent,
  readAutoResizeHeight,
  resolveFrameCanvasBackground,
} from '@/helpers/iframeAutoResize'

/** Minimal MessageEvent stand-in — the helpers only read `data`/`source`. */
const msg = (data: unknown, source: unknown = null): MessageEvent =>
  ({ data, source }) as unknown as MessageEvent

describe('clampFrameHeight', () => {
  it('keeps an in-range height', () => {
    expect(clampFrameHeight(640)).toBe(640)
  })

  it('clamps below the minimum (an empty/short frame must not collapse)', () => {
    expect(clampFrameHeight(12)).toBe(MIN_FRAME_HEIGHT)
  })

  it('clamps above the maximum (runaway content stays scrollable)', () => {
    expect(clampFrameHeight(99999)).toBe(MAX_FRAME_HEIGHT)
  })

  it('falls back to the minimum for a non-finite height', () => {
    expect(clampFrameHeight(Number.NaN)).toBe(MIN_FRAME_HEIGHT)
    expect(clampFrameHeight(Number.POSITIVE_INFINITY)).toBe(MAX_FRAME_HEIGHT)
  })

  it('honours explicit bounds (the preview HTML iframe uses 200..2000)', () => {
    expect(clampFrameHeight(10, 200, 2000)).toBe(200)
    expect(clampFrameHeight(5000, 200, 2000)).toBe(2000)
  })
})

describe('readAutoResizeHeight', () => {
  it('reads the height reported by its own source tag', () => {
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 812 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBe(812)
  })

  it("ignores another consumer's frames (preview vs chat tags)", () => {
    expect(
      readAutoResizeHeight(
        msg({ source: PREVIEW_AUTO_RESIZE_SOURCE, height: 812 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
  })

  it('ignores foreign / malformed messages', () => {
    expect(readAutoResizeHeight(msg(null), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(readAutoResizeHeight(msg('hello'), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(readAutoResizeHeight(msg({}), CHAT_HTML_FRAME_RESIZE_SOURCE)).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 'tall' }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
    expect(
      readAutoResizeHeight(
        msg({ source: CHAT_HTML_FRAME_RESIZE_SOURCE, height: 0 }),
        CHAT_HTML_FRAME_RESIZE_SOURCE,
      ),
    ).toBeNull()
  })
})

describe('findSenderFrame', () => {
  it('returns the frame whose contentWindow sent the message', () => {
    document.body.innerHTML =
      '<iframe class="chat-html-frame" id="a"></iframe>' +
      '<iframe class="chat-html-frame" id="b"></iframe>'
    const frames = document.querySelectorAll<HTMLIFrameElement>('.chat-html-frame')
    const target = frames[1]
    expect(target?.contentWindow).toBeTruthy()

    const found = findSenderFrame(document, msg({}, target?.contentWindow), '.chat-html-frame')
    expect(found).toBe(target)
  })

  it('returns null for a sender that is not one of our frames', () => {
    document.body.innerHTML = '<iframe class="chat-html-frame" id="a"></iframe>'
    const frames = document.querySelectorAll<HTMLIFrameElement>('.chat-html-frame')
    expect(
      findSenderFrame(document, msg({}, frames[0]?.contentWindow), 'iframe.chat-preview-frame'),
    ).toBeNull()
    expect(findSenderFrame(document, msg({}, window), 'iframe.chat-html-frame')).toBeNull()
    expect(findSenderFrame(document, msg({}, null), 'iframe.chat-html-frame')).toBeNull()
  })
})

describe('autoResizeScript', () => {
  it("tags the report with the caller's source and posts it to the parent", () => {
    const script = autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE)
    expect(script).toContain(JSON.stringify(CHAT_HTML_FRAME_RESIZE_SOURCE))
    expect(script).toContain('parent.postMessage')
    expect(script).toContain('scrollHeight')
    // Emitted as a real script element (the helper splits the tag so the
    // literal can live in a TS source file without closing it early).
    expect(script.startsWith('<script>')).toBe(true)
    expect(script.endsWith('</script>')).toBe(true)
    // The script itself must not close a surrounding <script> block early:
    // only the final tag exists.
    expect(script.split('</script>').length - 1).toBe(1)
  })

  it('pre-tags the preview HTML iframe with its own source', () => {
    expect(PREVIEW_AUTO_RESIZE_SCRIPT).toContain(JSON.stringify(PREVIEW_AUTO_RESIZE_SOURCE))
  })
})

const computedStyleWith = (value: string): CSSStyleDeclaration =>
  ({ getPropertyValue: () => value }) as unknown as CSSStyleDeclaration

describe('frameDocumentStyle (the canvas a preview frame paints)', () => {
  it('paints the frame document instead of a hardcoded white', () => {
    const style = frameDocumentStyle('#123456')
    expect(style).toContain('background:#123456')
    expect(style).not.toContain('#fff')
    expect(style).toContain(FRAME_NO_SCROLLBAR_STYLE)
    expect(style.startsWith('<style>')).toBe(true)
    expect(style.endsWith('</style>')).toBe(true)
  })

  it("uses the app's card surface when the theme variable resolves", () => {
    const spy = vi.spyOn(window, 'getComputedStyle').mockReturnValue(computedStyleWith('#1d1c19'))
    try {
      expect(resolveFrameCanvasBackground()).toBe('#1d1c19')
      expect(frameDocumentStyle()).toContain('background:#1d1c19')
    } finally {
      spy.mockRestore()
    }
  })

  it('falls back to the dark card tone when the variable is unset', () => {
    const spy = vi.spyOn(window, 'getComputedStyle').mockReturnValue(computedStyleWith(''))
    try {
      expect(resolveFrameCanvasBackground()).toBe(FRAME_CANVAS_FALLBACK)
    } finally {
      spy.mockRestore()
    }
  })
})

describe('the frame height report (a number the frame itself must not influence)', () => {
  const reporterSource = () =>
    autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE).slice('<script>'.length, -'</script>'.length)

  /** What the browser measures for a frame whose viewport is `frameHeight` px over a document with
   * `bodyHeight` px of body content. jsdom lays nothing out, so these numbers ARE the input; the
   * return value is the height the reporter posts — the only thing the parent acts on. */
  interface FrameGeometry {
    /** The frame's own viewport (`window.innerHeight`). */
    frameHeight: number
    /** The body content box the reflowed document reports. */
    bodyHeight: number
    /** The root element's scroll extent — inflated by body margins and by viewport-floored layout. */
    rootScrollHeight: number
  }

  const reportedHeight = (geometry: FrameGeometry): number => {
    const posted: number[] = []
    const postSpy = vi.spyOn(window, 'postMessage').mockImplementation(((message: unknown) => {
      const payload = message as { source?: string; height?: number }
      if (payload?.source === CHAT_HTML_FRAME_RESIZE_SOURCE) posted.push(Number(payload.height))
    }) as unknown as typeof window.postMessage)
    const restoreInnerHeight = Object.getOwnPropertyDescriptor(window, 'innerHeight')
    const define = (target: object, prop: string, value: number): void => {
      Object.defineProperty(target, prop, {
        configurable: true,
        get: () => value,
      })
    }

    Object.defineProperty(window, 'innerHeight', {
      configurable: true,
      value: geometry.frameHeight,
    })
    document.body.innerHTML = '<div id="card">report</div>'
    define(document.documentElement, 'scrollHeight', geometry.rootScrollHeight)
    define(document.documentElement, 'offsetHeight', geometry.frameHeight)
    define(document.body, 'scrollHeight', geometry.bodyHeight)
    define(document.body, 'offsetHeight', geometry.bodyHeight)
    vi.spyOn(document.body, 'getBoundingClientRect').mockReturnValue({
      height: geometry.bodyHeight,
    } as DOMRect)

    try {
      new Function(reporterSource())()
    } finally {
      postSpy.mockRestore()
      vi.restoreAllMocks()
      if (restoreInnerHeight) {
        Object.defineProperty(window, 'innerHeight', restoreInnerHeight)
      }
      for (const prop of ['scrollHeight', 'offsetHeight']) {
        Reflect.deleteProperty(document.body, prop)
        Reflect.deleteProperty(document.documentElement, prop)
      }
    }

    expect(posted).toHaveLength(1)
    return posted[0] ?? -1
  }

  it('reports the content height when the content outgrows a short frame', () => {
    expect(
      reportedHeight({
        frameHeight: 120,
        bodyHeight: 900,
        rootScrollHeight: 900,
      }),
    ).toBe(900)
  })

  it('reports a height the frame can adopt without changing the next report', () => {
    // The ratchet: a report the parent applies must be the report the reflowed document produces,
    // or every cycle moves the frame again — forever, in 16px body-margin steps.
    const first = reportedHeight({
      frameHeight: 120,
      bodyHeight: 600,
      rootScrollHeight: 616,
    })
    const second = reportedHeight({
      frameHeight: first,
      bodyHeight: 600,
      rootScrollHeight: first,
    })

    expect(first).toBe(600)
    expect(second).toBe(first)
  })

  it('ignores a root extent larger than the body box', () => {
    // A positioned overlay extends the root's scroll area without adding body content; letting it
    // through grows a frame around something nobody can see.
    expect(
      reportedHeight({
        frameHeight: 600,
        bodyHeight: 584,
        rootScrollHeight: 620,
      }),
    ).toBe(584)
  })

  it('falls back to the frame height when the document reports nothing', () => {
    expect(reportedHeight({ frameHeight: 150, bodyHeight: 0, rootScrollHeight: 0 })).toBe(150)
  })

  it('re-reports on resize-observer ticks, not only childList mutations', () => {
    // A tab switch flips class/style only: no childList mutation ever fires for it.
    expect(reporterSource()).toContain('new ResizeObserver(report)')
  })
})

describe('growFrameToContent (no inner scrollbar)', () => {
  it('grows past the old 2000px cap instead of clipping behind a scrollbar', () => {
    expect(growFrameToContent(5000)).toBe(5000)
    expect(growFrameToContent(99999)).toBe(99999)
  })

  it('keeps the minimum floor for empty/short frames', () => {
    expect(growFrameToContent(12)).toBe(MIN_FRAME_HEIGHT)
    expect(growFrameToContent(0)).toBe(MIN_FRAME_HEIGHT)
    expect(growFrameToContent(Number.NaN)).toBe(MIN_FRAME_HEIGHT)
  })

  it('hides page-level scrollbars without touching inner pre scrolling', () => {
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('overflow:hidden')
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('scrollbar-width:none')
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('::-webkit-scrollbar')
  })

  it('sizes the root against its content, never against the frame viewport', () => {
    // `html{height:100%}` in the shell would make the root as tall as the frame the parent is
    // about to size from this document's report — the loop that clipped and ratcheted reports.
    expect(FRAME_NO_SCROLLBAR_STYLE).toContain('html{height:auto!important}')
  })
})

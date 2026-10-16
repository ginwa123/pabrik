/** Shared "content iframe reports its own height" protocol. A sandboxed content iframe
 * (`sandbox="allow-scripts"`, NULL origin) cannot be measured from the parent — `contentDocument`
 * is off-limits, so the parent has no way to learn the height of what the frame rendered. */
export const PREVIEW_AUTO_RESIZE_SOURCE = 'show-preview-auto-resize'

/** Reporter tag for ChatView's `<html>` wrapper-tag iframes. */
export const CHAT_HTML_FRAME_RESIZE_SOURCE = 'chat-html-frame-auto-resize'

/** Lower bound the parent enforces on a reported content height — an
 *  empty/short frame must not collapse to zero (it has a visible border). */
export const MIN_FRAME_HEIGHT = 120

/** Upper bound — runaway content (huge dashboards, infinite scroll) must not break the chat layout;
 * those frames stay scrollable instead. */
export const MAX_FRAME_HEIGHT = 2000

/**  * Clamp a reported content height into the accepted range. `NaN` (a metric that could not be read)
 * falls back to the minimum; infinities clamp to the matching bound. */
export function clampFrameHeight(
  height: number,
  min: number = MIN_FRAME_HEIGHT,
  max: number = MAX_FRAME_HEIGHT,
): number {
  if (Number.isNaN(height)) return min
  return Math.max(min, Math.min(max, height))
}

/**  * Grow a frame to its full reported content height with no upper bound. HTML frames use this (not
 * clampFrameHeight) so long reports never get an inner scrollbar — the outer chat scroller owns
 * scrolling. */
export function growFrameToContent(height: number, min: number = MIN_FRAME_HEIGHT): number {
  if (!Number.isFinite(height) || height <= 0) return min
  return Math.max(min, height)
}

/** CSS snippet injected into every HTML srcdoc shell so the frame document itself never shows
 * scrollbars. */
export const FRAME_NO_SCROLLBAR_STYLE =
  'html,body{overflow:hidden!important;scrollbar-width:none!important}' +
  'html::-webkit-scrollbar,body::-webkit-scrollbar{display:none!important}'

/** Canvas colour for a preview frame when the app's CSS variables are unreachable (no DOM) or unset.
 * Matches `--semantic-card-bg` in style.css. */
export const FRAME_CANVAS_FALLBACK = '#1d1c19'

/** Resolve what a preview frame's DOCUMENT canvas paints. A sandboxed srcdoc frame is a separate
 * document, so the parent's CSS custom properties never reach it — the colour must be a literal. */
export function resolveFrameCanvasBackground(): string {
  if (typeof document === 'undefined') return FRAME_CANVAS_FALLBACK
  const raw = getComputedStyle(document.documentElement)
    .getPropertyValue('--semantic-card-bg')
    .trim()
  return raw === '' ? FRAME_CANVAS_FALLBACK : raw
}

/** `<style>` shell prepended to a fetched HTML document inside a preview frame: paints the canvas
 * with the app surface — NEVER a hardcoded `#fff`, which shows as a bright slab in the dark theme
 * wherever the document's own `body` box does not cover the canvas. */
export function frameDocumentStyle(canvas: string = resolveFrameCanvasBackground()): string {
  return `<style>html,body{margin:0;padding:0;background:${canvas};}${FRAME_NO_SCROLLBAR_STYLE}</style>`
}

/**  * Read a sender's reported height out of a `message` event. Returns `null` for anything that isn't
 * this protocol (a different `source` tag, a non-object payload, a missing/NaN height) so callers
 * can bail before touching the DOM. */
export function readAutoResizeHeight(event: MessageEvent, source: string): number | null {
  const data: unknown = event.data
  if (!data || typeof data !== 'object') return null
  const payload = data as { source?: unknown; height?: unknown }
  if (payload.source !== source) return null
  const height = Number(payload.height)
  if (!Number.isFinite(height) || height <= 0) return null
  return height
}

/** Resolve the iframe that sent `event` by identity-comparing the message's `source` window against
 * the frames currently in the DOM. */
export function findSenderFrame(
  root: ParentNode,
  event: MessageEvent,
  selector: string,
): HTMLIFrameElement | null {
  const frames = root.querySelectorAll<HTMLIFrameElement>(selector)
  for (const frame of frames) {
    if (frame.contentWindow === event.source) return frame
  }
  return null
}

/** Build the reporter script for a frame's srcdoc. Injected into the srcdoc document itself, so it
 * runs at parse time inside the sandbox, reporting on load / resize / mutation / resize-observer —
 * so the frame also SHRINKS when a scripted document collapses (a tab switch, a folded section). */
export function autoResizeScript(source: string): string {
  return (
    `<script>(function(){
var REPORT_SOURCE = ${JSON.stringify(source)};
function measure(){
  var de = document.documentElement;
  var body = document.body;
  var h = 0, w = 0;
  if (body) {
    h = Math.max(
      body.scrollHeight,
      body.offsetHeight,
      Math.ceil(body.getBoundingClientRect().height)
    );
    w = Math.max(body.scrollWidth, body.offsetWidth);
  }
  if (de) {
    if (de.scrollHeight > window.innerHeight) h = Math.max(h, de.scrollHeight);
    w = Math.max(w, de.scrollWidth);
  }
  if (h <= 0) h = de ? de.offsetHeight : 0;
  return { height: h, width: w };
}
function report(){
  try {
    var box = measure();
    parent.postMessage({ source: REPORT_SOURCE, height: box.height, width: box.width }, '*');
  } catch(e) {}
}
function init(){
  report();
  window.addEventListener('load', report);
  window.addEventListener('resize', report);
  if (document.body && typeof MutationObserver !== 'undefined') {
    try {
      new MutationObserver(report).observe(document.body, { childList: true, subtree: true });
    } catch(e) {}
  }
  if (document.body && typeof ResizeObserver !== 'undefined') {
    try {
      new ResizeObserver(report).observe(document.body);
    } catch(e) {}
  }
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
})();<` + `/script>`
  )
}

/** The reporter script pre-tagged for the preview HTML iframe. */
export const PREVIEW_AUTO_RESIZE_SCRIPT = autoResizeScript(PREVIEW_AUTO_RESIZE_SOURCE)

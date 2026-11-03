import { activeScheme } from '../theme/runtime'

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

/** CSS shell for every content frame: no page-level scrollbars, and the frame's own viewport is
 * never an input to its layout — `height:100%` resolves against the CONTENT, so a percentage-height
 * document reports its real height instead of echoing the frame the parent is about to size. */
export const FRAME_NO_SCROLLBAR_STYLE =
  'html{height:auto!important}' +
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
 * with the app surface (never a hardcoded `#fff`, which shows as a bright slab in the dark theme) and
 * declares the theme's scheme so the frame's native controls match it. */
export function frameDocumentStyle(canvas: string = resolveFrameCanvasBackground()): string {
  return `<style>html,body{margin:0;padding:0;background:${canvas};color-scheme:${activeScheme()};}${FRAME_NO_SCROLLBAR_STYLE}</style>`
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

/** Build the reporter script injected into a frame's srcdoc: reports on load / resize / mutation so
 * the frame also SHRINKS. It measures the BODY content box only — `documentElement.scrollHeight` is
 * floored by the frame's own height, so max-ing it in made every report resize its own input. */
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
  if (de) w = Math.max(w, de.scrollWidth);
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

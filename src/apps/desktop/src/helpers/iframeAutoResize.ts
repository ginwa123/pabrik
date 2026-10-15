/**
 * Shared "content iframe reports its own height" protocol.
 *
 * A sandboxed content iframe (`sandbox="allow-scripts"`, NULL origin)
 * cannot be measured from the parent — `contentDocument` is off-limits, so
 * the parent has no way to learn the height of what the frame rendered.
 * The frame therefore measures ITSELF and `postMessage`s the result back;
 * the parent's only job is writing a clamped `iframe.style.height`.
 *
 * Without this, every such frame keeps the browser's default iframe height
 * (150 px) and long content ends up behind an inner scrollbar — an iframe
 * inside a scroller inside the chat.
 *
 * Two consumers, each with its own `source` token so that a message is only
 * ever applied to the frame that sent it (both listeners see every
 * `message` on the window):
 *
 *   - `PreviewContentRenderer.vue`  → `show-preview-auto-resize`
 *   - `ChatView.vue` `<html>` blocks → `chat-html-frame-auto-resize`
 *
 * Security: the injected script has no network access, no `eval`, and no
 * parent-DOM access. It reads its own document metrics and posts one plain
 * object. The parent's handler only writes a clamped pixel height.
 */
/** Reporter tag for the inline preview HTML iframe. */
export const PREVIEW_AUTO_RESIZE_SOURCE = 'show-preview-auto-resize'

/** Reporter tag for ChatView's `<html>` wrapper-tag iframes. */
export const CHAT_HTML_FRAME_RESIZE_SOURCE = 'chat-html-frame-auto-resize'

/** Lower bound the parent enforces on a reported content height — an
 *  empty/short frame must not collapse to zero (it has a visible border). */
export const MIN_FRAME_HEIGHT = 120

/** Upper bound — runaway content (huge dashboards, infinite scroll) must not break the chat layout;
 * those frames stay scrollable instead. */
/** NOTE (2026-09-20 no-inner-scrollbar): HTML frames no longer clamp to this max — they grow to
 * their full content height so the outer chat scroller owns scrolling and no inner scrollbar ever
 * appears. Kept for backward compat (clampFrameHeight default) only. */
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
/** The parent sizes the iframe element to the content height (see growFrameToContent), so
 * page-level scrolling inside the frame is never needed — inner `pre` blocks keep their own
 * `overflow-x:auto` for wide code. */
export const FRAME_NO_SCROLLBAR_STYLE =
  'html,body{overflow:hidden!important;scrollbar-width:none!important}' +
  'html::-webkit-scrollbar,body::-webkit-scrollbar{display:none!important}'

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
/** A null-origin sandbox forbids reading `contentDocument`, but the `WindowProxy` is still
 * comparable — `event.source === frame.contentWindow` is the one handle the parent keeps on an
 * otherwise opaque frame. */
/** Querying the DOM at message time (rather than holding refs) keeps this correct with
 * VirtualScroller, which mounts/unmounts message rows. Returns `null` when the sender isn't one of
 * ours. */
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
 * runs at parse time inside the sandbox. It reports once immediately and again on load / resize /
 * DOM mutation (so streamed-in or script-driven content keeps the frame sized). */
/** `</script>` is emitted as `<\/script>` so the literal can live inside the generated document
 * without closing the parent's script context. */
export function autoResizeScript(source: string): string {
  return (
    `<script>(function(){
var REPORT_SOURCE = ${JSON.stringify(source)};
function report(){
  try {
    var de = document.documentElement;
    var body = document.body;
    var h = Math.max(
      de ? de.scrollHeight : 0,
      body ? body.scrollHeight : 0,
      de ? de.offsetHeight : 0,
      body ? body.offsetHeight : 0
    );
    var w = Math.max(
      de ? de.scrollWidth : 0,
      body ? body.scrollWidth : 0,
      de ? de.offsetWidth : 0,
      body ? body.offsetWidth : 0
    );
    parent.postMessage({ source: REPORT_SOURCE, height: h, width: w }, '*');
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

export {
  stripThinkingTags,
  getThinkingTags,
  isThinkingTags,
  getHtmlTags,
  isHtmlTags,
} from './stripTags'
export { default as VirtualScroller } from './VirtualScroller.vue'
export { formatRelativeTime } from './relativeTime'
export {
  createScrollLogger,
  buildScrollContext,
  BOTTOM_THRESHOLD,
  AT_BOTTOM_STABLE_TOLERANCE_PX,
  TOP_THRESHOLD,
  markProgrammatic,
} from './scrollLogger'
export type {
  ScrollContext,
  ScrollLogger,
  ScrollOrigin,
  ScrollReason,
  ContainerInfo,
} from './scrollLogger'
export { isAutoStickActive, AUTO_STICK_GATE_MS } from './autoStickGate'
export {
  decidePrefetchOlder,
  armRadiusPx,
  nextFetchEstimate,
  ARM_RADIUS_FLOOR_PX,
  ARM_RADIUS_RATIO,
  PREFETCH_SAMPLE_INIT_MS,
  FETCH_EMA_ALPHA,
  FETCH_SAMPLE_MIN_MS,
  FETCH_SAMPLE_MAX_MS,
} from './prefetchOlderMessages'
export type { PrefetchDecision, PrefetchInput, PrefetchSkip } from './prefetchOlderMessages'
export { renderResponse } from './renderResponse'
export { formatCompactTokens } from './formatCompact'
export {
  PREVIEW_AUTO_RESIZE_SOURCE,
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  MIN_FRAME_HEIGHT,
  MAX_FRAME_HEIGHT,
  clampFrameHeight,
  growFrameToContent,
  FRAME_NO_SCROLLBAR_STYLE,
  readAutoResizeHeight,
  findSenderFrame,
  autoResizeScript,
  PREVIEW_AUTO_RESIZE_SCRIPT,
} from './iframeAutoResize'

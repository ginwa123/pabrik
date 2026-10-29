import {
  CHAT_HTML_FRAME_RESIZE_SOURCE,
  FRAME_NO_SCROLLBAR_STYLE,
  autoResizeScript,
  findSenderFrame,
  growFrameToContent,
  readAutoResizeHeight,
} from './iframeAutoResize'
import { activeScheme, activeTheme } from '../theme/runtime'

/**
 * The frame is a separate NULL-origin document, so app CSS custom properties do not cascade in.
 */
export interface HtmlFramePalette {
  bg: string
  fg: string
  muted: string
  border: string
  link: string
  chip: string
  codeInk: string
}

export const HTML_FRAME_PALETTE_FALLBACK: HtmlFramePalette = {
  bg: '#1D1C19',
  fg: '#c5c9c5',
  muted: '#a6a69c',
  border: '#282727',
  link: '#8ba4b0',
  chip: '#282727',
  codeInk: '#8ea4a2',
}

let htmlFramePalette: HtmlFramePalette | null = null
let htmlFramePaletteTheme: string | null = null

const readCssVar = (name: string, fallback: string): string => {
  if (typeof window === 'undefined' || typeof getComputedStyle !== 'function') return fallback
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return value || fallback
}

/** Memoized PER THEME: this runs on every assistant render, and a theme flip must re-read the
 * tokens rather than reuse the shell painted for the previous theme. */
export const resolveHtmlFramePalette = (): HtmlFramePalette => {
  const theme = activeTheme()
  if (htmlFramePalette && htmlFramePaletteTheme === theme) return htmlFramePalette
  const fallback = HTML_FRAME_PALETTE_FALLBACK
  htmlFramePalette = {
    bg: readCssVar('--semantic-card-bg', fallback.bg),
    fg: readCssVar('--semantic-text', fallback.fg),
    muted: readCssVar('--semantic-text-muted', fallback.muted),
    border: readCssVar('--color-border', fallback.border),
    link: readCssVar('--semantic-link', fallback.link),
    chip: readCssVar('--color-bg-p1', fallback.chip),
    codeInk: readCssVar('--color-aqua', fallback.codeInk),
  }
  htmlFramePaletteTheme = theme
  return htmlFramePalette
}

/** Documents pass through verbatim; fragments get a themed shell plus the resize reporter. */
export const buildHtmlSrcdoc = (block: string): string => {
  const trimmed = block.trim()
  if (/<!doctype html|<html[\s>]/i.test(trimmed)) {
    const noScrollbar = `<style>${FRAME_NO_SCROLLBAR_STYLE}</style>`
    const reporter = autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE)
    if (/<\/body\s*>/i.test(trimmed)) {
      return trimmed.replace(/<\/body\s*>/i, `${noScrollbar}${reporter}</body>`)
    }
    return `${trimmed}${noScrollbar}${reporter}`
  }
  const p = resolveHtmlFramePalette()
  return (
    '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<style>' +
    ':root{color-scheme:' +
    activeScheme() +
    '}' +
    'html,body{margin:0;padding:0}' +
    `body{font-family:system-ui,sans-serif;background:${p.bg};color:${p.fg};margin:8px}` +
    `a{color:${p.link}}` +
    'img{max-width:100%}' +
    `pre,code,th,td{background:${p.chip}!important;color:${p.fg}!important}` +
    'code{font-family:ui-monospace,"SF Mono",Menlo,monospace;padding:.1em .3em;border-radius:3px}' +
    `code{color:${p.codeInk}!important}` +
    'pre{font-family:ui-monospace,"SF Mono",Menlo,monospace;padding:.6em .8em;' +
    'border-radius:4px;overflow-x:auto}' +
    'pre code{background:transparent!important;padding:0}' +
    `pre code{color:${p.fg}!important}` +
    'table{border-collapse:collapse}' +
    `th,td{border:1px solid ${p.border};padding:4px 8px}` +
    `hr{border:none;border-top:1px solid ${p.border}}` +
    `blockquote{margin:.6em 0;padding-left:.8em;border-left:3px solid ${p.border};color:${p.muted}}` +
    FRAME_NO_SCROLLBAR_STYLE +
    '</style>' +
    '</head><body>' +
    trimmed +
    '</body>' +
    autoResizeScript(CHAT_HTML_FRAME_RESIZE_SOURCE) +
    '</html>'
  )
}

/** Grow the frame to its reported height: `contentWindow` identity is the only handle left. */
export const onHtmlFrameResize = (event: MessageEvent): void => {
  const reported = readAutoResizeHeight(event, CHAT_HTML_FRAME_RESIZE_SOURCE)
  if (reported === null) return
  const frame = findSenderFrame(document, event, 'iframe.chat-html-frame')
  if (!frame) return
  frame.style.height = `${growFrameToContent(reported)}px`
}

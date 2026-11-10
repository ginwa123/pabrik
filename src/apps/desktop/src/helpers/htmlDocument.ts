export const HTML_FORMAT = 'html'

export function isHtmlFormat(format: string | null | undefined): boolean {
  return format === HTML_FORMAT
}

export type HtmlViewportId = 'desktop' | 'tablet' | 'mobile' | 'custom'

export interface HtmlViewport {
  id: HtmlViewportId
  label: string
  /** The preview width in CSS pixels; `null` fills the stage (desktop) or is
   *  the user's own number (custom). */
  width: number | null
}

export const HTML_VIEWPORTS: readonly HtmlViewport[] = [
  { id: 'desktop', label: 'Desktop', width: null },
  { id: 'tablet', label: 'Tablet', width: 768 },
  { id: 'mobile', label: 'Mobile', width: 390 },
  { id: 'custom', label: 'Custom', width: null },
]

export const DEFAULT_HTML_VIEWPORT: HtmlViewportId = 'desktop'

/** What the Custom field starts at, and what a cleared field falls back to. */
export const DEFAULT_CUSTOM_WIDTH = 400

export const MIN_CUSTOM_WIDTH = 240
export const MAX_CUSTOM_WIDTH = 2560

/** A usable pixel width: a non-number falls back to the default, and anything
 *  outside the range is clamped rather than rendering a 0px or 40 000px frame. */
export function clampWidth(value: unknown): number {
  const width = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(width)) return DEFAULT_CUSTOM_WIDTH
  return Math.min(MAX_CUSTOM_WIDTH, Math.max(MIN_CUSTOM_WIDTH, Math.round(width)))
}

export function viewportWidth(id: HtmlViewportId, customWidth: unknown): number | null {
  if (id === 'custom') return clampWidth(customWidth)
  return HTML_VIEWPORTS.find((viewport) => viewport.id === id)?.width ?? null
}

export const DEFAULT_HTML_BODY = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Untitled page</title>
    <style>
      body {
        margin: 0;
        padding: 2rem;
        font-family: system-ui, sans-serif;
        line-height: 1.5;
      }
    </style>
  </head>
  <body>
    <h1>Untitled page</h1>
    <p>Start writing your page.</p>
  </body>
</html>
`

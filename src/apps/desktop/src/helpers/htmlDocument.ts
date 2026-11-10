export const HTML_FORMAT = 'html'

export function isHtmlFormat(format: string | null | undefined): boolean {
  return format === HTML_FORMAT
}

export type HtmlViewportId = 'desktop' | 'tablet' | 'mobile'

export interface HtmlViewport {
  id: HtmlViewportId
  label: string
  /** The preview width in CSS pixels; `null` fills the stage. */
  width: number | null
}

export const HTML_VIEWPORTS: readonly HtmlViewport[] = [
  { id: 'desktop', label: 'Desktop', width: null },
  { id: 'tablet', label: 'Tablet', width: 768 },
  { id: 'mobile', label: 'Mobile', width: 390 },
]

export const DEFAULT_HTML_VIEWPORT: HtmlViewportId = 'desktop'

export function viewportWidth(id: HtmlViewportId): number | null {
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

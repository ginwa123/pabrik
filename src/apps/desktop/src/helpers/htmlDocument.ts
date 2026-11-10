export const HTML_FORMAT = 'html'

export function isHtmlFormat(format: string | null | undefined): boolean {
  return format === HTML_FORMAT
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

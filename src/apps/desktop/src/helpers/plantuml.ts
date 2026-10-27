/** PlantUML has no in-browser renderer (it is a Java program), so a `<plantuml>` block becomes an
 * `<img>` whose src is a PlantUML server URL carrying the source — nothing cached, no Java needed. */
export const PLANTUML_DEFAULT_SERVER = 'https://www.plantuml.com/plantuml'

/** A trailing slash on the configured value would produce `//svg` — a 404 from most servers. */
const withoutTrailingSlash = (value: string): string => value.replace(/\/+$/, '')

/** `VITE_PLANTUML_SERVER` points this at the deployment's own PlantUML instance (a `plantuml.war`
 * serves the same `/plantuml/svg/<encoded>` path) so diagram source need not leave the box. */
export const resolvePlantumlServer = (): string => {
  // Cast rather than `import.meta.env.X`: outside a Vite build (plain node, a unit test) `env` may
  // be absent entirely, and reading a property off it would throw instead of falling back.
  const env = (import.meta as { env?: Record<string, string | undefined> }).env
  const value = (env?.VITE_PLANTUML_SERVER ?? '').trim()
  return withoutTrailingSlash(value.length > 0 ? value : PLANTUML_DEFAULT_SERVER)
}

/** PlantUML's UNCOMPRESSED link form: `~h` + the source bytes as lowercase hex. The usual `~1` form
 * is that source deflated with PlantUML's own base64 alphabet, which needs a compressor the browser
 * does not reliably have; hex doubles the bytes, and a 40-arrow diagram is still only a ~2.4 KB URL. */
export const encodePlantuml = (source: string): string => {
  const bytes = new TextEncoder().encode(source)
  let hex = ''
  for (const byte of bytes) hex += byte.toString(16).padStart(2, '0')
  return `~h${hex}`
}

/** The SVG URL for one block. `server` is injectable so tests never hit the network. */
export const plantumlSvgUrl = (source: string, server: string = resolvePlantumlServer()): string =>
  `${withoutTrailingSlash(server)}/svg/${encodePlantuml(source)}`

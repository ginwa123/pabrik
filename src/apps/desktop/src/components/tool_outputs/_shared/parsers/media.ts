import { asRecord, numOrNullField, strField, strOrNullField, unwrapDataRecord } from './internal'

// ─── generate_image ──────────────────────────────────────────────────────── Parses the JSON
// `data` payload produced by `execute_generate_image` in
// `src/modules/agent/tools/generate_image.zig`:.
export interface ParsedGenerateImage {
  status: string | null
  count: number | null
  model: string | null
  size: string | null
  /** Absolute filesystem path of each saved image (DALL-E / gpt-image-1 save to disk). */
  images: Array<{ index: number; path: string; bytes: number; mime: string }>
  /** DALL-E 3 / gpt-image-1 only — null for DALL-E 2 (which doesn't rewrite). */
  revisedPrompt: string | null
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

export function parseGenerateImage(data: unknown): ParsedGenerateImage {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return {
      status: null,
      count: null,
      model: null,
      size: null,
      images: [],
      revisedPrompt: null,
      error,
    }
  }
  const images: ParsedGenerateImage['images'] = []
  const imagesRaw = Array.isArray(o.images) ? o.images : []
  for (const item of imagesRaw) {
    const r = asRecord(item)
    images.push({
      index: numOrNullField(r, 'index') ?? 0,
      path: strField(r, 'path'),
      bytes: numOrNullField(r, 'bytes') ?? 0,
      mime: strField(r, 'mime') || 'image/png',
    })
  }

  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count'),
    model: strOrNullField(o, 'model'),
    size: strOrNullField(o, 'size'),
    images,
    revisedPrompt: strOrNullField(o, 'revised_prompt'),
    error: null,
  }
}

// ─── present_files ───────────────────────────────────────────────────────── Parses the JSON
// `data` payload produced by `executePresentFilesToString` in
// `src/modules/agent/tools/present_files.zig`: {"status":"presented","count":2,"files":[.
export interface ParsedPresentFile {
  path: string
  bytes: number
  mime: string
  label: string
}

export interface ParsedPresentFiles {
  status: string | null
  count: number | null
  files: ParsedPresentFile[]
  /** null on success, populated on <error>...</error>. */
  error: string | null
}

function parsePresentFileRecord(item: unknown): ParsedPresentFile {
  const r = asRecord(item)
  return {
    path: strField(r, 'path'),
    bytes: numOrNullField(r, 'bytes') ?? 0,
    mime: strField(r, 'mime') || 'application/octet-stream',
    label: strField(r, 'label'),
  }
}

export function parsePresentFiles(data: unknown): ParsedPresentFiles {
  const o = unwrapDataRecord(data)
  const error = strOrNullField(o, 'error')
  if (error !== null) {
    return { status: null, count: null, files: [], error }
  }
  const files: ParsedPresentFile[] = []
  const filesRaw = Array.isArray(o.files) ? o.files : []
  for (const item of filesRaw) {
    files.push(parsePresentFileRecord(item))
  }
  return {
    status: strOrNullField(o, 'status'),
    count: numOrNullField(o, 'count') ?? files.length,
    files,
    error: null,
  }
}

/** True for renderable image mimes (thumbnail preview before download). */
export function isPreviewableImage(mime: string): boolean {
  return mime.toLowerCase().startsWith('image/')
}

/** Basename of an absolute path (`/a/b/c.jpg` → `c.jpg`). */
export function basenameOfPath(path: string): string {
  const idx = path.lastIndexOf('/')
  return idx === -1 ? path : path.slice(idx + 1)
}

/** Human-readable byte size (`48211` → `47.1 KB`). */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '0 B'
  if (n < 1024) return `${n} B`
  const units = ['KB', 'MB', 'GB']
  let v = n / 1024
  let u = 0
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024
    u += 1
  }
  return `${v.toFixed(1)} ${units[u]}`
}

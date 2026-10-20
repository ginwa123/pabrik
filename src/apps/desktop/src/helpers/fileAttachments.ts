import { Effect, Either } from 'effect'

/** The chat's file attachments: the shape the backend accepts on the wire, the accept policy, and
 * the codec. Base64 has no quotes or backslashes, so the array is safe to embed in a JSON string. */
export interface FileAttachment {
  name: string
  mime: string
  b64: string
}

/** One attached file as the read path reports it — the bytes never cross the read path. */
export interface AttachedFileMeta {
  name: string
  mime: string
  bytes: number
}

/** Cap on the total decoded size of the files in one message (10 MB — mirrors the image cap). */
export const MAX_FILE_ATTACHMENT_BYTES = 10 * 1024 * 1024

/** Cap on how many files one message may carry. */
export const MAX_FILE_ATTACHMENT_COUNT = 8

/** MIME types the model reads as plain text even though they are not `text/*`. */
const TEXTUAL_MIMES = new Set([
  'application/json',
  'application/xml',
  'application/javascript',
  'application/x-javascript',
  'application/ecmascript',
  'application/typescript',
  'application/x-yaml',
  'application/yaml',
  'application/toml',
  'application/sql',
  'application/x-sh',
  'application/x-httpd-php',
  'application/graphql',
  'application/x-ndjson',
])

/** MIME types of the rich binary documents only the Responses API accepts. */
const RICH_BINARY_MIMES = new Set([
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.oasis.opendocument.text',
  'application/vnd.oasis.opendocument.spreadsheet',
  'application/vnd.oasis.opendocument.presentation',
  'application/rtf',
])

/** Extensions that are text even when the browser reports no MIME type. */
const TEXTUAL_EXTENSIONS = new Set([
  'txt',
  'md',
  'markdown',
  'csv',
  'tsv',
  'json',
  'jsonl',
  'ndjson',
  'xml',
  'yaml',
  'yml',
  'toml',
  'ini',
  'cfg',
  'conf',
  'log',
  'html',
  'htm',
  'css',
  'scss',
  'less',
  'sql',
  'graphql',
  'gql',
  'js',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'jsx',
  'vue',
  'svelte',
  'py',
  'rb',
  'go',
  'rs',
  'java',
  'kt',
  'kts',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'php',
  'sh',
  'bash',
  'zsh',
  'fish',
  'swift',
  'm',
  'mm',
  'pl',
  'pm',
  'lua',
  'dart',
  'scala',
  'hs',
  'ex',
  'exs',
  'erl',
  'clj',
  'zig',
  'nim',
  'r',
  'jl',
  'tf',
  'hcl',
  'proto',
  'env',
  'gitignore',
  'dockerfile',
  'makefile',
  'mk',
  'gradle',
  'cmake',
  'patch',
  'diff',
])

/** Extensions of the rich binary documents, for browsers that report no MIME type. */
const RICH_BINARY_EXTENSIONS = new Set([
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
  'odt',
  'ods',
  'odp',
  'rtf',
])

/** The `accept` attribute of the paperclip picker — the file types the chat takes. */
export const FILE_ATTACHMENT_ACCEPT =
  'image/*,video/*,.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.odt,.ods,.odp,.rtf,' +
  '.txt,.md,.markdown,.csv,.tsv,.json,.jsonl,.ndjson,.xml,.yaml,.yml,.toml,.ini,.cfg,.conf,.log,' +
  '.html,.htm,.css,.scss,.less,.sql,.graphql,.gql,.js,.mjs,.cjs,.ts,.tsx,.jsx,.vue,.svelte,' +
  '.py,.rb,.go,.rs,.java,.kt,.kts,.c,.h,.cc,.cpp,.hpp,.cs,.php,.sh,.bash,.zsh,.fish,.swift,' +
  '.m,.mm,.pl,.pm,.lua,.dart,.scala,.hs,.ex,.exs,.erl,.clj,.zig,.nim,.r,.jl,.tf,.hcl,.proto,' +
  '.env,.gitignore,.dockerfile,.makefile,.mk,.gradle,.cmake,.patch,.diff'

/** The lowercased extension of `name`, without the dot. Empty when there is none. */
export function fileExtension(name: string): string {
  const dot = name.lastIndexOf('.')
  if (dot < 0 || dot + 1 >= name.length) return ''
  return name.slice(dot + 1).toLowerCase()
}

/** True when the MIME is one the model reads as plain text. */
export function isTextualMime(mime: string): boolean {
  if (!mime) return false
  return mime.startsWith('text/') || TEXTUAL_MIMES.has(mime)
}

/** True when the MIME is a PDF. */
export function isPdfMime(mime: string): boolean {
  return mime.toLowerCase() === 'application/pdf'
}

/** True when the MIME is a rich binary document. */
export function isRichBinaryMime(mime: string): boolean {
  return RICH_BINARY_MIMES.has(mime.toLowerCase())
}

/** True when the file is a PDF. */
export function isPdfFile(file: File): boolean {
  return isPdfMime(file.type) || fileExtension(file.name) === 'pdf'
}

/** True when the file is a document the model reads as plain text. */
export function isTextualFile(file: File): boolean {
  if (isTextualMime(file.type)) return true
  const ext = fileExtension(file.name)
  return ext !== '' && TEXTUAL_EXTENSIONS.has(ext)
}

/** True when the file is a rich binary document (doc/docx/xls/xlsx/ppt/pptx/odt/rtf). */
export function isRichBinaryFile(file: File): boolean {
  if (isRichBinaryMime(file.type)) return true
  const ext = fileExtension(file.name)
  return ext !== '' && RICH_BINARY_EXTENSIONS.has(ext)
}

/** True when the file is a document the chat can attach (a PDF, a text document, or a rich
 * binary document). */
export function isDocumentFile(file: File): boolean {
  return isPdfFile(file) || isTextualFile(file) || isRichBinaryFile(file)
}

/** True when the wire style can carry this file. Only the Responses API takes a rich binary
 * document; every style takes a PDF, and a text document is sent as text everywhere. */
export function styleCarriesFile(urlStyle: string | undefined | null, file: File): boolean {
  if (isTextualFile(file)) return true
  if (isPdfFile(file)) return true
  // An unknown style means the client cannot tell — let the backend decide.
  if (!urlStyle) return true
  if (isRichBinaryFile(file)) return urlStyle === 'openai-response'
  return false
}

/** Read a file as the wire attachment: the raw base64 payload, with no data-URL prefix. */
export function fileToAttachment(file: File): Promise<FileAttachment> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      const dataUrl = String(reader.result ?? '')
      const comma = dataUrl.indexOf(',')
      resolve({
        name: file.name,
        mime: file.type || 'application/octet-stream',
        b64: comma >= 0 ? dataUrl.slice(comma + 1) : '',
      })
    }
    reader.onerror = () => reject(reader.error ?? new Error('Failed to read the file'))
    reader.readAsDataURL(file)
  })
}

/** Encode the attachments for the wire — a JSON array in ONE field, like `tags`. */
export function encodeFileAttachmentsWire(files: readonly FileAttachment[]): string {
  return JSON.stringify(files.map((f) => ({ name: f.name, mime: f.mime, b64: f.b64 })))
}

/** Parse the metadata the read path emits. `Effect.try` moves a throw into the error channel and
 * `Effect.either` turns it into a VALUE, so `runSync` here cannot throw. */
export function parseFileAttachmentsMeta(raw?: string | null): AttachedFileMeta[] {
  if (!raw) return []
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: () => JSON.parse(raw) as unknown,
        catch: () => new Error('not valid JSON'),
      }),
    ),
  )
  if (Either.isLeft(outcome)) return []
  if (!Array.isArray(outcome.right)) return []
  return outcome.right
    .filter(
      (entry): entry is Record<string, unknown> => typeof entry === 'object' && entry !== null,
    )
    .filter((entry) => typeof entry.name === 'string')
    .map((entry) => ({
      name: String(entry.name),
      mime: typeof entry.mime === 'string' ? entry.mime : '',
      bytes: typeof entry.bytes === 'number' ? entry.bytes : 0,
    }))
}

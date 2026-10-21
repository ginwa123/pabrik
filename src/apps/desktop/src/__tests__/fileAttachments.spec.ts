/** The chat's file attachments: what the client accepts, what it puts on the wire, and what it
 * reads back from the read path. */
import { describe, it, expect } from 'vitest'
import {
  encodeFileAttachmentsWire,
  fileExtension,
  isDocumentFile,
  isPdfFile,
  isRichBinaryFile,
  isTextualFile,
  parseFileAttachmentsMeta,
  styleCarriesFile,
} from '@/helpers/fileAttachments'

const makeFile = (name: string, type: string): File =>
  new File([new Uint8Array([1, 2, 3])], name, { type })

describe('fileAttachments — what the chat accepts', () => {
  it('reads a pdf by mime or by extension', () => {
    expect(isPdfFile(makeFile('a.pdf', 'application/pdf'))).toBe(true)
    expect(isPdfFile(makeFile('a.pdf', ''))).toBe(true)
    expect(isPdfFile(makeFile('a.txt', 'text/plain'))).toBe(false)
  })

  it('reads a text document by mime or by extension', () => {
    expect(isTextualFile(makeFile('notes.md', 'text/markdown'))).toBe(true)
    expect(isTextualFile(makeFile('notes.md', ''))).toBe(true)
    expect(isTextualFile(makeFile('data.json', 'application/json'))).toBe(true)
    expect(isTextualFile(makeFile('main.zig', ''))).toBe(true)
    expect(isTextualFile(makeFile('doc.pdf', 'application/pdf'))).toBe(false)
  })

  it('reads a rich binary document', () => {
    expect(isRichBinaryFile(makeFile('a.docx', ''))).toBe(true)
    expect(
      isRichBinaryFile(
        makeFile(
          'a.docx',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
      ),
    ).toBe(true)
    expect(isRichBinaryFile(makeFile('a.pdf', 'application/pdf'))).toBe(false)
  })

  it('refuses a type the model has no way to read', () => {
    expect(isDocumentFile(makeFile('a.exe', 'application/octet-stream'))).toBe(false)
    expect(isDocumentFile(makeFile('a.bin', ''))).toBe(false)
  })

  it('reads the lowercased extension of a name', () => {
    expect(fileExtension('notes.MD')).toBe('md')
    expect(fileExtension('no-extension')).toBe('')
    expect(fileExtension('trailing.')).toBe('')
  })
})

describe('fileAttachments — which wire style carries a file', () => {
  it('carries a pdf on every style', () => {
    const pdf = makeFile('a.pdf', 'application/pdf')
    expect(styleCarriesFile('openai', pdf)).toBe(true)
    expect(styleCarriesFile('openai-response', pdf)).toBe(true)
    expect(styleCarriesFile('anthropic', pdf)).toBe(true)
  })

  it('carries a rich binary document only on the responses api', () => {
    const docx = makeFile('a.docx', '')
    expect(styleCarriesFile('openai-response', docx)).toBe(true)
    expect(styleCarriesFile('openai', docx)).toBe(false)
    expect(styleCarriesFile('anthropic', docx)).toBe(false)
  })

  it('lets the backend decide when the style is unknown', () => {
    const docx = makeFile('a.docx', '')
    expect(styleCarriesFile(undefined, docx)).toBe(true)
    expect(styleCarriesFile('', docx)).toBe(true)
  })
})

describe('fileAttachments — the wire format', () => {
  it('encodes the attachments as a JSON array in ONE field', () => {
    const encoded = encodeFileAttachmentsWire([
      { name: 'a.pdf', mime: 'application/pdf', b64: 'aGk=' },
    ])
    expect(JSON.parse(encoded)).toEqual([{ name: 'a.pdf', mime: 'application/pdf', b64: 'aGk=' }])
  })

  it('encodes no attachments as an empty array', () => {
    expect(JSON.parse(encodeFileAttachmentsWire([]))).toEqual([])
  })
})

describe('fileAttachments — the metadata the read path emits', () => {
  it('reads the name, the mime and the size of every file', () => {
    const meta = parseFileAttachmentsMeta(
      '[{"name":"doc.pdf","mime":"application/pdf","bytes":2048}]',
    )
    expect(meta).toEqual([{ name: 'doc.pdf', mime: 'application/pdf', bytes: 2048 }])
  })

  it('reads nothing from an absent or broken field', () => {
    expect(parseFileAttachmentsMeta(undefined)).toEqual([])
    expect(parseFileAttachmentsMeta('')).toEqual([])
    expect(parseFileAttachmentsMeta('not json')).toEqual([])
    expect(parseFileAttachmentsMeta('{"name":"x"}')).toEqual([])
  })
})

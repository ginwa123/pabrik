import type { Document, DocumentFolder } from '../api'

/** One rendered row of the Documents tree: a folder or a document, at a depth. */
export type DocumentRow =
  | { kind: 'folder'; folder: DocumentFolder; depth: number }
  | { kind: 'document'; document: Document; depth: number }

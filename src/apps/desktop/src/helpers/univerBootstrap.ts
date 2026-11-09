import type { OfficeKind } from './officeDocument'

/** A mounted Univer editor, reduced to what the document view needs. */
export interface OfficeEditor {
  /** The current content as a Univer snapshot, ready to store. */
  snapshot(): unknown
  /** Run `listener` after every command the user executes. Returns an unsubscribe. */
  onEdit(listener: () => void): () => void
  dispose(): void
}

interface UniverUnit {
  save(): unknown
}

interface UniverFacade {
  createDocument(data: Record<string, unknown>): UniverUnit
  createWorkbook(data: Record<string, unknown>): UniverUnit
  addEvent(event: string, callback: () => void): { dispose(): void }
  Event: { CommandExecuted: string }
}

/**
 * Mount a Univer editor of `kind`. Univer is imported HERE and nowhere else.
 */
export async function mountOfficeEditor(
  container: HTMLElement,
  kind: OfficeKind,
  snapshot: Record<string, unknown>,
): Promise<OfficeEditor> {
  const { createUniver, LocaleType, merge, defaultTheme } = await import('@univerjs/presets')

  const locale = LocaleType.EN_US
  const base = { locale, theme: defaultTheme }

  let univer: { dispose(): void }
  let univerAPI: UniverFacade
  let unit: UniverUnit

  if (kind === 'doc') {
    const [{ UniverDocsCorePreset }, messages] = await Promise.all([
      import('@univerjs/preset-docs-core'),
      import('@univerjs/preset-docs-core/locales/en-US'),
      import('@univerjs/preset-docs-core/lib/index.css'),
    ])
    const created = createUniver({
      ...base,
      locales: { [locale]: merge({}, messages.default) },
      presets: [UniverDocsCorePreset({ container })],
    })
    univer = created.univer
    univerAPI = created.univerAPI as unknown as UniverFacade
    unit = univerAPI.createDocument(snapshot)
  } else {
    const [{ UniverSheetsCorePreset }, messages] = await Promise.all([
      import('@univerjs/preset-sheets-core'),
      import('@univerjs/preset-sheets-core/locales/en-US'),
      import('@univerjs/preset-sheets-core/lib/index.css'),
    ])
    const created = createUniver({
      ...base,
      locales: { [locale]: merge({}, messages.default) },
      // An empty `workerURL` keeps the formula engine on the main thread: the
      // worker is optional at runtime, and shipping one means a second bundle.
      presets: [UniverSheetsCorePreset({ container, workerURL: '' })],
    })
    univer = created.univer
    univerAPI = created.univerAPI as unknown as UniverFacade
    unit = univerAPI.createWorkbook(snapshot)
  }

  const listeners = new Set<() => void>()
  const subscription = univerAPI.addEvent(univerAPI.Event.CommandExecuted, () => {
    for (const listener of listeners) listener()
  })

  return {
    snapshot: () => unit.save(),
    onEdit(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    dispose() {
      listeners.clear()
      subscription.dispose()
      univer.dispose()
    },
  }
}

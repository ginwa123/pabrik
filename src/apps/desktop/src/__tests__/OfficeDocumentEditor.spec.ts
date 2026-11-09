/** The office editor's own behaviour: it mounts the right Univer product, it
 *  reports edits, and it never leaves a live Univer behind. The SDK itself is
 *  mocked — jsdom cannot evaluate it, and the point here is the wiring. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'

import OfficeDocumentEditor from '../components/workspace/OfficeDocumentEditor.vue'

const mountOfficeEditor = vi.hoisted(() => vi.fn())

vi.mock('../helpers/univerBootstrap', () => ({ mountOfficeEditor }))

interface FakeEditor {
  snapshot: ReturnType<typeof vi.fn>
  onEdit: ReturnType<typeof vi.fn>
  dispose: ReturnType<typeof vi.fn>
  fireEdit: () => void
}

function fakeEditor(snapshot: unknown = { sheets: {} }): FakeEditor {
  const listeners = new Set<() => void>()
  return {
    snapshot: vi.fn(() => snapshot),
    onEdit: vi.fn((listener: () => void) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }),
    dispose: vi.fn(),
    fireEdit: () => {
      for (const listener of listeners) listener()
    },
  }
}

beforeEach(() => {
  mountOfficeEditor.mockReset()
})

describe('OfficeDocumentEditor — mounting', () => {
  it('mounts the kind the body names, with its snapshot', async () => {
    const editor = fakeEditor()
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, {
      props: { body: JSON.stringify({ kind: 'doc', snapshot: { body: { dataStream: 'hi' } } }) },
    })
    await flushPromises()

    expect(mountOfficeEditor).toHaveBeenCalledTimes(1)
    const [container, kind, snapshot] = mountOfficeEditor.mock.calls[0] as [
      HTMLElement,
      string,
      Record<string, unknown>,
    ]
    expect(container).toBeInstanceOf(HTMLElement)
    expect(kind).toBe('doc')
    expect(snapshot).toEqual({ body: { dataStream: 'hi' } })
    wrapper.unmount()
  })

  it('an empty body opens a blank spreadsheet', async () => {
    const editor = fakeEditor()
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()

    const [, kind, snapshot] = mountOfficeEditor.mock.calls[0] as [
      HTMLElement,
      string,
      Record<string, unknown>,
    ]
    expect(kind).toBe('sheet')
    expect(snapshot).toEqual({})
    wrapper.unmount()
  })

  it('an unreadable body is reported instead of mounting an editor over it', async () => {
    const wrapper = mount(OfficeDocumentEditor, { props: { body: 'not json' } })
    await flushPromises()

    expect(mountOfficeEditor).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="office-document-editor-error"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="office-document-editor-surface"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('a mount failure is rendered, not swallowed', async () => {
    mountOfficeEditor.mockRejectedValue(new Error('worker exploded'))

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()

    expect(wrapper.get('[data-testid="office-document-editor-error"]').text()).toContain(
      'worker exploded',
    )
    wrapper.unmount()
  })
})

describe('OfficeDocumentEditor — edits and teardown', () => {
  it('reports a change when the editor runs a command', async () => {
    const editor = fakeEditor()
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()

    expect(wrapper.emitted('change')).toBeUndefined()
    editor.fireEdit()
    expect(wrapper.emitted('change')).toHaveLength(1)
    wrapper.unmount()
  })

  it('exposes the current snapshot for Save', async () => {
    const editor = fakeEditor({ sheets: { s1: {} } })
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()

    expect(wrapper.vm.snapshot()).toEqual({ sheets: { s1: {} } })
    wrapper.unmount()
  })

  it('reports the kind it mounted, so Save can label the snapshot', async () => {
    const editor = fakeEditor()
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, {
      props: { body: JSON.stringify({ kind: 'doc', snapshot: {} }) },
    })
    await flushPromises()

    // The view stores the snapshot under this kind. If it re-parsed the body
    // instead, a body that changed underneath the editor could label a
    // workbook as a document.
    expect(wrapper.vm.kind()).toBe('doc')
    wrapper.unmount()
  })

  it('reports no kind before the editor is ready', async () => {
    mountOfficeEditor.mockReturnValue(new Promise(() => {}))

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()

    expect(wrapper.vm.kind()).toBeNull()
    wrapper.unmount()
  })

  it('unmounting disposes the editor and stops listening', async () => {
    const editor = fakeEditor()
    mountOfficeEditor.mockResolvedValue(editor)

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    await flushPromises()
    wrapper.unmount()

    expect(editor.dispose).toHaveBeenCalledTimes(1)
    // A listener that outlives the component would emit into a dead view.
    editor.fireEdit()
    expect(wrapper.emitted('change')).toBeUndefined()
  })

  it('an editor that arrives after unmount is disposed, not leaked', async () => {
    const editor = fakeEditor()
    let resolveMount: (value: FakeEditor) => void = () => {}
    mountOfficeEditor.mockReturnValue(
      new Promise<FakeEditor>((resolve) => {
        resolveMount = resolve
      }),
    )

    const wrapper = mount(OfficeDocumentEditor, { props: { body: '' } })
    wrapper.unmount()
    resolveMount(editor)
    await flushPromises()

    expect(editor.dispose).toHaveBeenCalledTimes(1)
  })
})

// Behavioural tests for AgentKnowledgeDetailDialog (plan 2026-08-22-agent-mode-ui-ux, Feature A2 +
// user extension: full edit with File↔Text mode switch).

// Covers open/populate, save payloads per mode, mode switching (file→text and text→file), path
// validation, busy/error rendering, and the canSubmit gating.

// NOTE (vue-teleport-vitest-document-queryselector): the dialog uses <Teleport to="body"> (+ a
// nested FilePickerDialog), so wrapper.find() can't see the teleported DOM.

// Mount with attachTo: document.body and assert via document.querySelector + native .click();
// wrapper.emitted() still works because it tracks the vm, not the DOM tree.

import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentKnowledgeDetailDialog from '../components/dialogs/AgentKnowledgeDetailDialog.vue'
import * as api from '../api'
import type { AgentKnowledgeRow } from '../api'

const inlineRow: AgentKnowledgeRow = {
  id: 'k_inline',
  agent_id: 'item_1',
  file_path: '',
  label: 'Notes',
  content: 'Existing inline body.',
  position: 0,
  created_at: '',
  updated_at: '',
}

const fileRow: AgentKnowledgeRow = {
  id: 'k_file',
  agent_id: 'item_1',
  file_path: '/home/me/spec.md',
  label: 'Spec',
  content: '',
  position: 1,
  created_at: '',
  updated_at: '',
}

let wrapper: VueWrapper | null = null

function mountDialog(props: {
  show: boolean
  row: AgentKnowledgeRow | null
  busy?: boolean
  error?: string | null
}) {
  // attachTo: document.body — required so the teleported content lands
  // in the live document where document.querySelector can find it.
  wrapper = mount(AgentKnowledgeDetailDialog, { props, attachTo: document.body })
  return wrapper
}

function q<T extends Element = HTMLElement>(testid: string): T {
  const el = document.querySelector<T>(`[data-testid="${testid}"]`)
  if (!el) throw new Error(`missing [data-testid="${testid}"] in teleported DOM`)
  return el
}

function maybeQ<T extends Element = HTMLElement>(testid: string): T | null {
  return document.querySelector<T>(`[data-testid="${testid}"]`)
}

/** Set an input/textarea value through the live DOM (teleported). */
async function setValue(testid: string, value: string) {
  const el = q<HTMLInputElement | HTMLTextAreaElement>(testid)
  el.value = value
  el.dispatchEvent(new Event('input'))
  await nextTick()
}

afterEach(() => {
  // Teleported DOM survives between tests — unmount + force-remove.
  wrapper?.unmount()
  wrapper = null
  document
    .querySelectorAll('[data-testid="agent-knowledge-detail-dialog"]')
    .forEach((el) => el.remove())
})

describe('AgentKnowledgeDetailDialog', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    // Browse picker network calls are stubbed; not every test opens it.
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({ path: '/', absolute: '/', home: '/', entries: [] })
    vi.spyOn(api, 'listFolder').mockResolvedValue({ path: '/', absolute: '/', home: '/', entries: [] })
  })

  it('renders nothing when show=false', () => {
    mountDialog({ show: false, row: inlineRow })
    expect(maybeQ('agent-knowledge-detail-dialog')).toBeNull()
  })

  it('populates label + content from an inline row when opened', async () => {
    const w = mountDialog({ show: false, row: inlineRow })
    await w.setProps({ show: true })
    await nextTick()
    expect(q<HTMLInputElement>('agent-knowledge-detail-label').value).toBe('Notes')
    expect(q<HTMLTextAreaElement>('agent-knowledge-detail-content').value).toBe('Existing inline body.')
    // Inline rows open in text mode.
    expect(maybeQ('agent-knowledge-detail-content')).not.toBeNull()
  })

  it('populates label + path from a file-backed row when opened', async () => {
    const w = mountDialog({ show: false, row: fileRow })
    await w.setProps({ show: true })
    await nextTick()
    expect(q<HTMLInputElement>('agent-knowledge-detail-label').value).toBe('Spec')
    expect(q<HTMLInputElement>('agent-knowledge-detail-path').value).toBe('/home/me/spec.md')
    // File-backed rows open in file mode (no textarea).
    expect(maybeQ('agent-knowledge-detail-content')).toBeNull()
  })

  it('emits save with {label, content, file_path:""} for inline rows in text mode', async () => {
    const w = mountDialog({ show: false, row: inlineRow })
    await w.setProps({ show: true })
    await nextTick()
    await setValue('agent-knowledge-detail-label', 'Renamed')
    await setValue('agent-knowledge-detail-content', 'New body text')
    q('agent-knowledge-detail-save').click()
    await nextTick()
    const events = w.emitted('save')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual([
      'k_inline',
      { label: 'Renamed', content: 'New body text', file_path: '' },
    ])
  })

  it('emits save with {label, file_path, content:""} for file rows in file mode', async () => {
    const w = mountDialog({ show: false, row: fileRow })
    await w.setProps({ show: true })
    await nextTick()
    await setValue('agent-knowledge-detail-label', 'Better name')
    await setValue('agent-knowledge-detail-path', '/home/me/other.md')
    q('agent-knowledge-detail-save').click()
    await nextTick()
    expect(w.emitted('save')![0]).toEqual([
      'k_file',
      { label: 'Better name', file_path: '/home/me/other.md', content: '' },
    ])
  })

  it('switches from file mode to text mode and saves the flipped row', async () => {
    const w = mountDialog({ show: false, row: fileRow })
    await w.setProps({ show: true })
    await nextTick()
    // Flip to Text.
    q('agent-knowledge-detail-mode-text').click()
    await nextTick()
    expect(maybeQ('agent-knowledge-detail-content')).not.toBeNull()
    await setValue('agent-knowledge-detail-content', 'Converted to inline')
    q('agent-knowledge-detail-save').click()
    await nextTick()
    expect(w.emitted('save')![0]).toEqual([
      'k_file',
      { label: 'Spec', content: 'Converted to inline', file_path: '' },
    ])
  })

  it('switches from text mode to file mode and saves the flipped row', async () => {
    const w = mountDialog({ show: false, row: inlineRow })
    await w.setProps({ show: true })
    await nextTick()
    // Flip to File.
    q('agent-knowledge-detail-mode-file').click()
    await nextTick()
    expect(maybeQ('agent-knowledge-detail-content')).toBeNull()
    await setValue('agent-knowledge-detail-path', '/home/me/converted.md')
    q('agent-knowledge-detail-save').click()
    await nextTick()
    expect(w.emitted('save')![0]).toEqual([
      'k_inline',
      { label: 'Notes', file_path: '/home/me/converted.md', content: '' },
    ])
  })

  it('shows a path error and blocks submit for relative paths in file mode', async () => {
    const w = mountDialog({ show: false, row: inlineRow })
    await w.setProps({ show: true })
    await nextTick()
    q('agent-knowledge-detail-mode-file').click()
    await nextTick()
    await setValue('agent-knowledge-detail-path', 'relative/path.md')
    await nextTick()
    expect(q('agent-knowledge-detail-path-error').textContent).toContain('absolute')
    const save = q<HTMLButtonElement>('agent-knowledge-detail-save')
    expect(save.hasAttribute('disabled')).toBe(true)
    expect(w.emitted('save')).toBeFalsy()
  })

  it('Save is disabled while busy', async () => {
    mountDialog({ show: true, row: inlineRow, busy: true })
    await nextTick()
    const save = q<HTMLButtonElement>('agent-knowledge-detail-save')
    expect(save.hasAttribute('disabled')).toBe(true)
    expect(save.textContent).toContain('Saving…')
  })

  it('renders the error banner when error prop is set', async () => {
    mountDialog({ show: true, row: inlineRow, error: 'Server exploded' })
    await nextTick()
    expect(q('agent-knowledge-detail-error').textContent).toContain('Server exploded')
  })

  it('Cancel emits close (unless busy)', async () => {
    const w = mountDialog({ show: true, row: inlineRow })
    await nextTick()
    q('agent-knowledge-detail-cancel').click()
    await nextTick()
    expect(w.emitted('close')).toBeTruthy()

    const busyWrapper = mountDialog({ show: true, row: inlineRow, busy: true })
    await nextTick()
    q('agent-knowledge-detail-cancel').click()
    await nextTick()
    expect(busyWrapper.emitted('close')).toBeFalsy()
  })
})

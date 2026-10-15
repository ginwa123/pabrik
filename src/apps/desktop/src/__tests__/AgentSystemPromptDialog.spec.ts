// Behavioural tests for AgentSystemPromptDialog (plan
// 2026-08-21-agent-system-prompt, Task 4). Covers open/reset, create
// payload, edit/save payload, canSubmit gating (content required,
// whitespace-only rejected), busy/error rendering.
//
// NOTE (vue-teleport-vitest-document-queryselector): the dialog uses
// <Teleport to="body">, so wrapper.find() can't see the teleported DOM.
// Mount with attachTo: document.body and assert via document.querySelector
// + native .click(); wrapper.emitted() still works because it tracks the
// vm, not the DOM tree.
import { describe, expect, it, beforeEach, afterEach } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentSystemPromptDialog from '../components/dialogs/AgentSystemPromptDialog.vue'
import type { AgentSystemPromptRow } from '../api'

const existingRow: AgentSystemPromptRow = {
  id: 'asp_1',
  agent_id: 'item_1',
  title: 'Persona',
  content: 'You are a pirate captain.',
  position: 0,
  created_at: '',
  updated_at: '',
}

let wrapper: VueWrapper | null = null

function mountDialog(props: {
  show: boolean
  row?: AgentSystemPromptRow | null
  busy?: boolean
  error?: string | null
}) {
  wrapper = mount(AgentSystemPromptDialog, {
    props: { row: null, ...props },
    attachTo: document.body,
  })
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
    .querySelectorAll('[data-testid="agent-system-prompt-dialog"]')
    .forEach((n) => n.remove())
})

describe('AgentSystemPromptDialog', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders nothing when show=false', () => {
    mountDialog({ show: false })
    expect(maybeQ('agent-system-prompt-dialog')).toBeNull()
  })

  it('renders title input + content textarea when shown (add mode)', async () => {
    const w = mountDialog({ show: true })
    await nextTick()
    expect(q('agent-system-prompt-title')).toBeTruthy()
    expect(q('agent-system-prompt-content')).toBeTruthy()
    expect(w!.emitted()).not.toHaveProperty('create')
  })

  it('submit is disabled while content is empty', async () => {
    mountDialog({ show: true })
    await nextTick()
    await setValue('agent-system-prompt-title', 'Persona')
    const btn = q<HTMLButtonElement>('agent-system-prompt-submit')
    expect(btn.disabled).toBe(true)
  })

  it('submit is disabled for whitespace-only content', async () => {
    mountDialog({ show: true })
    await nextTick()
    await setValue('agent-system-prompt-content', '   \n\t ')
    const btn = q<HTMLButtonElement>('agent-system-prompt-submit')
    expect(btn.disabled).toBe(true)
  })

  it('emits create(title, content) on submit in add mode', async () => {
    const w = mountDialog({ show: true })
    await nextTick()
    await setValue('agent-system-prompt-title', 'Style')
    await setValue('agent-system-prompt-content', 'Be terse.')
    q<HTMLButtonElement>('agent-system-prompt-submit').click()
    await nextTick()
    const evt = w!.emitted('create')
    expect(evt).toBeTruthy()
    expect(evt![0]).toEqual(['Style', 'Be terse.'])
  })

  it('emits create with empty title when untitled', async () => {
    const w = mountDialog({ show: true })
    await nextTick()
    await setValue('agent-system-prompt-content', 'Just a body.')
    q<HTMLButtonElement>('agent-system-prompt-submit').click()
    await nextTick()
    expect(w!.emitted('create')![0]).toEqual(['', 'Just a body.'])
  })

  it('edit mode populates fields from row and emits save(id, updates)', async () => {
    const w = mountDialog({ show: true, row: existingRow })
    await nextTick()
    expect(q<HTMLInputElement>('agent-system-prompt-title').value).toBe('Persona')
    expect(q<HTMLTextAreaElement>('agent-system-prompt-content').value).toBe(
      'You are a pirate captain.',
    )
    await setValue('agent-system-prompt-content', 'Updated body.')
    q<HTMLButtonElement>('agent-system-prompt-submit').click()
    await nextTick()
    const evt = w!.emitted('save')
    expect(evt).toBeTruthy()
    expect(evt![0]).toEqual(['asp_1', { title: 'Persona', content: 'Updated body.' }])
  })

  it('renders error banner when error prop set', async () => {
    mountDialog({ show: true, error: 'Server exploded' })
    await nextTick()
    expect(q('agent-system-prompt-error').textContent).toContain('Server exploded')
  })

  it('disables submit while busy', async () => {
    mountDialog({ show: true, busy: true })
    await nextTick()
    await setValue('agent-system-prompt-content', 'body')
    expect(q<HTMLButtonElement>('agent-system-prompt-submit').disabled).toBe(true)
  })

  it('emits close on cancel click', async () => {
    const w = mountDialog({ show: true })
    await nextTick()
    q<HTMLButtonElement>('agent-system-prompt-cancel').click()
    await nextTick()
    expect(w!.emitted('close')).toBeTruthy()
  })
})

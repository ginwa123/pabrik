// Workspace secrets UI. The load-bearing assertion in this file is test 2: a stored secret value
// must NEVER reach the DOM — not masked, not hinted, not in a `title=` tooltip, not in a `data-*`
// attribute.
// `components/pabrik/McpServersSection.vue` is the shape we must not copy: it renders
// `maskValue(h.value)` for the body but puts the RAW value in a `:title=` on the same row, so
// hovering the masked text hands over the secret.
// The server never returns a value for a secret at all, and this component keeps it that way in
// both directions — nothing to render, and nothing to keep after a save.
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'

import type { Secret } from '../api'
import * as api from '../api'
import SecretsSection from '../components/workspace/SecretsSection.vue'
import WorkspaceSettingsView from '../components/views/WorkspaceSettingsView.vue'
import { makeLocalStorageStub } from './helpers'

// Only the four secrets calls are stubbed; everything else stays real so this spec can also import
// the real router (which pulls AppLayout, and through it the rest of the api module) without half
// of that module going undefined underneath it.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listSecrets: vi.fn(),
    createSecret: vi.fn(),
    updateSecret: vi.fn(),
    deleteSecret: vi.fn(),
  }
})

const mockList = api.listSecrets as unknown as ReturnType<typeof vi.fn>
const mockCreate = api.createSecret as unknown as ReturnType<typeof vi.fn>
const mockUpdate = api.updateSecret as unknown as ReturnType<typeof vi.fn>
const mockDelete = api.deleteSecret as unknown as ReturnType<typeof vi.fn>

/** Recognisable, never-real credential used to prove it stays out of the DOM. */
const SECRET_VALUE = 'sk-live-DO-NOT-LEAK-4242'

const baseSecret: Secret = {
  id: 'sec_1',
  name: 'STRIPE_API_KEY',
  created_at: '2026-10-02T10:00:00Z',
  updated_at: '2026-10-02T11:00:00Z',
}

function mountSection(props: Partial<InstanceType<typeof SecretsSection>['$props']> = {}) {
  return mount(SecretsSection, {
    props: {
      secrets: [],
      loading: false,
      loaded: true,
      error: null,
      saving: false,
      ...props,
    },
  })
}

/** ConfirmDialog / the rotate modal teleport to <body>, so scope to the document. */
function buttonsInDom(): HTMLButtonElement[] {
  return Array.from(document.body.querySelectorAll('button'))
}

function buttonByText(re: RegExp): HTMLButtonElement | undefined {
  return buttonsInDom().find((b) => re.test(b.textContent ?? ''))
}

describe('SecretsSection', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('renders one row per secret, with its name and a configured state', () => {
    const wrapper = mountSection({
      secrets: [baseSecret, { ...baseSecret, id: 'sec_2', name: 'GITHUB_TOKEN' }],
    })
    const rows = wrapper.findAll('[data-testid="secret-row"]')
    expect(rows).toHaveLength(2)
    expect(rows[0]?.text()).toContain('STRIPE_API_KEY')
    expect(rows[1]?.text()).toContain('GITHUB_TOKEN')
    for (const row of rows) {
      expect(row.find('[data-testid="configured-badge"]').exists()).toBe(true)
      expect(row.find('[data-testid="configured-badge"]').text()).toMatch(/configured/i)
    }
    // The row carries the timestamps the server does send.
    expect(rows[0]?.text()).not.toBe('STRIPE_API_KEY')
    expect(rows[0]?.find('[data-testid="secret-updated-at"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('never renders a secret value — not even if one arrives on the row payload', async () => {
    // The server never sends one. This test pins that the component does
    // not grow a path to display it even if a future payload carried it —
    // the exact leak shape McpServersSection has via its `:title=` tooltip.
    const leaky = {
      ...baseSecret,
      value: SECRET_VALUE,
      key_hint: SECRET_VALUE,
    } as unknown as Secret
    const wrapper = mountSection({ secrets: [leaky] })

    expect(wrapper.html()).not.toContain(SECRET_VALUE)
    expect(wrapper.find('[title*="sk-live"]').exists()).toBe(false)

    // ...and the same holds for a value the user just typed: the input is
    // a DOM property, never an attribute, and nothing echoes it back out.
    await wrapper.find('[data-testid="name-input"]').setValue('NEW_SECRET')
    await wrapper.find('[data-testid="value-input"]').setValue(SECRET_VALUE)
    expect(wrapper.html()).not.toContain(SECRET_VALUE)

    await wrapper.find('[data-testid="add-btn"]').trigger('click')
    expect(wrapper.html()).not.toContain(SECRET_VALUE)
    wrapper.unmount()
  })

  it('uses a write-only password input and offers no reveal toggle', async () => {
    const wrapper = mountSection({ secrets: [baseSecret] })

    const valueInputs = wrapper
      .findAll('input')
      .filter((i) => /value/i.test(i.attributes('data-testid') ?? ''))
    expect(valueInputs.length).toBeGreaterThan(0)
    for (const input of valueInputs) {
      expect(input.attributes('type')).toBe('password')
    }

    // No reveal / show / eye affordance anywhere — a stored value has
    // nothing behind it, so a reveal button would be a lie.
    const revealish = [...wrapper.findAll('button'), ...wrapper.findAll('[role="button"]')].filter(
      (el) =>
        /reveal|show|eye|unmask|peek/i.test(
          `${el.attributes('data-testid') ?? ''} ${el.attributes('aria-label') ?? ''} ${el.attributes('title') ?? ''}`,
        ),
    )
    expect(revealish).toHaveLength(0)

    // The rotate modal's value field is a password field too.
    await wrapper.find('[data-testid="rotate-btn"]').trigger('click')
    await flushPromises()
    const rotateInput = document.body.querySelector<HTMLInputElement>(
      '[data-testid="rotate-value-input"]',
    )
    expect(rotateInput).not.toBeNull()
    expect(rotateInput?.getAttribute('type')).toBe('password')
    wrapper.unmount()
  })

  it('clears the value input after a save so nothing lingers in local state', async () => {
    const wrapper = mountSection({ secrets: [] })
    await wrapper.find('[data-testid="name-input"]').setValue('STRIPE_API_KEY')
    await wrapper.find('[data-testid="value-input"]').setValue(SECRET_VALUE)
    await wrapper.find('[data-testid="add-btn"]').trigger('click')

    expect((wrapper.find('[data-testid="value-input"]').element as HTMLInputElement).value).toBe('')
    expect((wrapper.find('[data-testid="name-input"]').element as HTMLInputElement).value).toBe('')
    wrapper.unmount()
  })

  it('renders the empty state only once a list has actually loaded', () => {
    // Not fetched yet — an empty state here would be a lie about the
    // backend; the view is still waiting on it.
    expect(
      mountSection({ secrets: [], loaded: false }).find('[data-testid="empty-state"]').exists(),
    ).toBe(false)
    const wrapper = mountSection({ secrets: [], loaded: true })
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('renders the error the store hands it, with a retry — never a write-only ref', () => {
    const wrapper = mountSection({
      secrets: [],
      loaded: false,
      error: 'HTTP 500 Internal Server Error',
    })
    const banner = wrapper.find('[data-testid="error-message"]')
    expect(banner.exists()).toBe(true)
    expect(banner.text()).toContain('HTTP 500')
    expect(wrapper.find('[data-testid="retry-btn"]').exists()).toBe(true)
    // A failure must NOT masquerade as "no secrets yet".
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('emits add with the typed name and value', async () => {
    const wrapper = mountSection({ secrets: [] })
    await wrapper.find('[data-testid="name-input"]').setValue('STRIPE_API_KEY')
    await wrapper.find('[data-testid="value-input"]').setValue(SECRET_VALUE)
    await wrapper.find('[data-testid="add-btn"]').trigger('click')

    expect(wrapper.emitted('add')?.[0]).toEqual([{ name: 'STRIPE_API_KEY', value: SECRET_VALUE }])
    wrapper.unmount()
  })

  it('emits delete with the secret NAME, after the confirm dialog', async () => {
    const wrapper = mountSection({ secrets: [baseSecret], loaded: true })

    await wrapper.findAll('[data-testid="delete-btn"]')[0]?.trigger('click')
    await flushPromises()
    // Nothing is deleted on the first click — the ConfirmDialog is open.
    expect(wrapper.emitted('delete')).toBeUndefined()
    expect(document.body.querySelector('.fixed.inset-0')).not.toBeNull()

    const confirm = buttonByText(/^Delete$/)
    expect(confirm).toBeDefined()
    confirm!.click()
    await flushPromises()

    expect(wrapper.emitted('delete')?.[0]).toEqual(['STRIPE_API_KEY'])
    wrapper.unmount()
  })

  it('emits rotate with the new value and forgets it afterwards', async () => {
    const wrapper = mountSection({ secrets: [baseSecret], loaded: true })
    await wrapper.find('[data-testid="rotate-btn"]').trigger('click')
    await flushPromises()

    const input = document.body.querySelector<HTMLInputElement>(
      '[data-testid="rotate-value-input"]',
    )!
    input.value = SECRET_VALUE
    input.dispatchEvent(new Event('input'))
    await flushPromises()

    const save = document.body.querySelector<HTMLButtonElement>('[data-testid="rotate-save-btn"]')!
    save.click()
    await flushPromises()

    expect(wrapper.emitted('rotate')?.[0]).toEqual([
      { id: 'sec_1', name: 'STRIPE_API_KEY', value: SECRET_VALUE },
    ])
    // The modal is gone and nothing echoes the value anywhere.
    expect(document.body.querySelector('[data-testid="rotate-value-input"]')).toBeNull()
    expect(document.body.innerHTML).not.toContain(SECRET_VALUE)
    wrapper.unmount()
  })
})

// ─── WorkspaceSettingsView: the ?section= URL contract ──────────────────── A view that lives only
// in component state is unreachable by refresh, Back/Forward and a shared link.
// The repo rule is that every view switch writes the URL, so the tab strip below is a writable
// computed over `?section=` — the same shape `NalarSettings.vue` uses, and `section` is the key it
// owns. (`?tab=` belongs to browser tab-mode.)
async function makeSettingsRouter(query: Record<string, string> = {}) {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/app/:workspaceId/settings', component: { template: '<div />' } }],
  })
  await router.push({ path: '/app/ws_1/settings', query })
  await router.isReady()
  return router
}

async function mountSettings(router: ReturnType<typeof createRouter>) {
  const wrapper: VueWrapper = mount(WorkspaceSettingsView, {
    global: { plugins: [router], stubs: { Teleport: true } },
  })
  await flushPromises()
  return wrapper
}

describe('WorkspaceSettingsView (URL-backed sections)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    mockList.mockReset()
    mockCreate.mockReset()
    mockUpdate.mockReset()
    mockDelete.mockReset()
    mockList.mockResolvedValue({ secrets: [baseSecret], count: 1 })
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('restores the Secrets section from ?section=secrets on mount', async () => {
    const router = await makeSettingsRouter({ section: 'secrets' })
    const replace = vi.spyOn(router, 'replace')
    const wrapper = await mountSettings(router)

    expect(wrapper.find('[data-testid="secrets-section"]').exists()).toBe(true)
    expect(wrapper.find('[data-tab-id="secrets"][data-active="true"]').exists()).toBe(true)
    // The store fetched for the workspace in the path, not for a hardcoded id.
    expect(mockList).toHaveBeenCalledWith('ws_1')
    // Mounting on a deep link must not rewrite the URL out from under it.
    expect(replace).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('falls back to Overview when the URL carries no section', async () => {
    const router = await makeSettingsRouter()
    const wrapper = await mountSettings(router)
    expect(wrapper.find('[data-tab-id="overview"][data-active="true"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="secrets-section"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('a tab click writes ?section= via router.replace, keeping other params', async () => {
    const router = await makeSettingsRouter({ focus: 'alpha' })
    const replace = vi.spyOn(router, 'replace')
    const wrapper = await mountSettings(router)

    await wrapper.find('[data-tab-id="secrets"]').trigger('click')
    await flushPromises()

    expect(replace).toHaveBeenCalled()
    expect(router.currentRoute.value.query.section).toBe('secrets')
    expect(router.currentRoute.value.query.focus).toBe('alpha')
    expect(wrapper.find('[data-testid="secrets-section"]').exists()).toBe(true)

    // Back to the default tab and the param is stripped again — the same
    // "keep the URL clean" rule NalarSettings follows.
    await wrapper.find('[data-tab-id="overview"]').trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.section).toBeUndefined()
    expect(router.currentRoute.value.query.focus).toBe('alpha')
    wrapper.unmount()
  })

  it('renders a fetched secret through to the section, and never its value', async () => {
    const router = await makeSettingsRouter({ section: 'secrets' })
    const wrapper = await mountSettings(router)
    await flushPromises()

    expect(wrapper.find('[data-testid="secret-row"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('STRIPE_API_KEY')
    expect(wrapper.html()).not.toContain(SECRET_VALUE)
    wrapper.unmount()
  })

  it('surfaces a failed list load as a rendered error, not an empty list', async () => {
    mockList.mockRejectedValue(new Error('HTTP 503 Service Unavailable'))
    const router = await makeSettingsRouter({ section: 'secrets' })
    const wrapper = await mountSettings(router)
    await flushPromises()

    expect(wrapper.find('[data-testid="error-message"]').exists()).toBe(true)
    // "Could not load" must not read as "there are none".
    expect(wrapper.find('[data-testid="empty-state"]').exists()).toBe(false)
    wrapper.unmount()
  })
})

// ─── Route registration order ───────────────────────────────────────────── The one thing about
// this route that is not visible in a type checker: Vue Router matches in REGISTRATION order, and
// `/app/:workspaceId` sits directly below the new entry.
// Registered in the wrong place, `/app/ws_1/settings` resolves as `workspace` with
// `workspaceId='ws_1'` and the `/settings` segment is silently gone — the page would render the
// workspace view and no test of the view itself would notice.
// This asserts against the REAL route table, not a hand-rolled copy of it, so it fails if the entry
// is ever moved below its catch.
describe('workspace settings route registration', () => {
  it('resolves /app/:workspaceId/settings to the workspace-settings route', async () => {
    const real = (await import('../router/index')).default
    await real.push('/app/ws_1/settings')
    expect(real.currentRoute.value.name).toBe('workspace-settings')
    expect(real.currentRoute.value.params.workspaceId).toBe('ws_1')

    // …and the ?section= query survives, which is the whole point of the
    // URL contract: a shared link restores the same open section.
    await real.push('/app/ws_1/settings?section=secrets')
    expect(real.currentRoute.value.name).toBe('workspace-settings')
    expect(real.currentRoute.value.query.section).toBe('secrets')
  })

  it('leaves the bare /app/:workspaceId route catching on its own', async () => {
    const real = (await import('../router/index')).default
    await real.push('/app/ws_1')
    expect(real.currentRoute.value.name).toBe('workspace')
    expect(real.currentRoute.value.params.workspaceId).toBe('ws_1')
  })
})

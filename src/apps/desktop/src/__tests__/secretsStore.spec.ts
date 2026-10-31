// Workspace-secrets store. The behavior under test is what the reveal map may contain at any moment:
// one plaintext, for the row the user asked about, and only until the user hides it, switches
// workspace or deletes the row.
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import { useSecretsStore } from '../stores/secrets'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listSecrets: vi.fn(),
    createSecret: vi.fn(),
    updateSecret: vi.fn(),
    deleteSecret: vi.fn(),
    revealSecret: vi.fn(),
  }
})

const mockReveal = api.revealSecret as unknown as ReturnType<typeof vi.fn>
const mockDelete = api.deleteSecret as unknown as ReturnType<typeof vi.fn>

const SECRET_VALUE = 'sk-live-unsealed-on-request-4242'

function revealed(id: string, value = SECRET_VALUE) {
  return { secret: { id, name: 'STRIPE_API_KEY', value } }
}

describe('secrets store: reveal', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('keeps only the plaintext of the row that was asked for', async () => {
    mockReveal.mockResolvedValue(revealed('sec_1'))
    const store = useSecretsStore()

    const value = await store.revealSecret('ws_1', 'sec_1')

    expect(value).toBe(SECRET_VALUE)
    expect(mockReveal).toHaveBeenCalledWith('ws_1', 'sec_1')
    expect(store.revealed).toEqual({ sec_1: SECRET_VALUE })
    // Revealing is not a list refresh.
    expect(store.secrets).toEqual([])
  })

  it('a reveal that fails leaves nothing on screen and surfaces the reason', async () => {
    mockReveal.mockRejectedValue(new Error('HTTP 404 Not Found'))
    const store = useSecretsStore()

    const value = await store.revealSecret('ws_1', 'sec_1')

    expect(value).toBeNull()
    // The critical half: a failed unseal must not read as a revealed value.
    expect(store.revealed).toEqual({})
    expect(store.error).toContain('404')
    expect(store.revealing).toBeNull()
  })

  it('hiding puts away one row and leaves the others alone', async () => {
    mockReveal.mockResolvedValueOnce(revealed('sec_1')).mockResolvedValueOnce(revealed('sec_2'))
    const store = useSecretsStore()

    await store.revealSecret('ws_1', 'sec_1')
    await store.revealSecret('ws_1', 'sec_2')
    expect(Object.keys(store.revealed)).toEqual(['sec_1', 'sec_2'])

    store.hideSecret('sec_1')
    expect(store.revealed).toEqual({ sec_2: SECRET_VALUE })
  })

  it('switching workspace forgets every plaintext', async () => {
    mockReveal.mockResolvedValue(revealed('sec_1'))
    const store = useSecretsStore()

    await store.revealSecret('ws_1', 'sec_1')
    store.reset()

    // One workspace's credential must not survive under another's header.
    expect(store.revealed).toEqual({})
    expect(store.revealing).toBeNull()
  })

  it('deleting a row forgets the plaintext that belonged to it', async () => {
    mockReveal.mockResolvedValueOnce(revealed('sec_1')).mockResolvedValueOnce(revealed('sec_2'))
    mockDelete.mockResolvedValue({ id: 'sec_1', success: true })
    const store = useSecretsStore()

    await store.revealSecret('ws_1', 'sec_1')
    await store.revealSecret('ws_1', 'sec_2')
    await store.deleteSecret('ws_1', 'sec_1')

    expect(store.revealed).toEqual({ sec_2: SECRET_VALUE })
  })

  it('a list never populates the reveal map, even if the payload grows a value', async () => {
    const listSecrets = api.listSecrets as unknown as ReturnType<typeof vi.fn>
    listSecrets.mockResolvedValue({
      secrets: [
        {
          id: 'sec_1',
          name: 'STRIPE_API_KEY',
          created_at: '2026-10-02T10:00:00Z',
          updated_at: '2026-10-02T11:00:00Z',
          value: SECRET_VALUE,
        },
      ],
      count: 1,
    })
    const store = useSecretsStore()

    await store.fetchSecrets('ws_1')

    expect(store.secrets).toHaveLength(1)
    expect(store.revealed).toEqual({})
  })
})

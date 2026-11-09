/** Tests for the composer's agent cascade — `useChatComposerAgents` owns it now that the chip is
 * gone. The `@` list in FileInput renders `availableAgents`; the cascade itself is data. */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ref } from 'vue'

import * as api from '../api'
import { useChatComposerAgents } from '../components/views/chat_view/useChatComposerAgents'

const TWO_PROFILES = {
  profiles: {
    '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
    '900ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
  },
  active_profile: '300 ribu',
}

/** Mount the composable the way ChatView does: a session id ref, a workspace resolver and the
 * chat-view-mode sink. `loadAgents()` is the one async step. */
async function loadComposer(
  config: Record<string, unknown>,
  opts: { workspaceId?: string; sessionId?: string } = {},
) {
  const applyChatViewMode = vi.fn()
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue(config as never)
  vi.spyOn(api, 'getWorkspaceConfig').mockResolvedValue(config as never)
  const composer = useChatComposerAgents({
    sessionId: ref(opts.sessionId ?? 'sess_cascade'),
    workspaceId: () => opts.workspaceId ?? '',
    applyChatViewMode,
  })
  await composer.loadAgents()
  return { composer, applyChatViewMode }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe('composer agent cascade — effectiveAgent', () => {
  it('resolves to the active profile when the session has no selection (active = default)', async () => {
    const { composer, applyChatViewMode } = await loadComposer(TWO_PROFILES)

    expect(composer.selectedAgent.value).toBeNull()
    expect(composer.activeAgent.value).toBe('300 ribu')
    expect(composer.effectiveAgent.value).toBe('300 ribu')
    // The tooltip the chip used to show is still the cascade's own words.
    expect(composer.agentChipTooltip.value).toMatch(/active agent/i)
    expect(composer.agentChipTooltip.value).not.toMatch(/default/i)
    // The config this chat fetched is the one that decides the view mode.
    expect(applyChatViewMode).toHaveBeenCalledWith(TWO_PROFILES)
  })

  it('falls through to the active profile when the session selection is empty', async () => {
    const { composer } = await loadComposer(TWO_PROFILES)
    composer.selectedAgent.value = ''

    expect(composer.effectiveAgent.value).toBe('300 ribu')
    expect(composer.agentChipTooltip.value).toMatch(/active agent/i)
  })

  it('prefers the per-session selection over the active profile', async () => {
    const { composer } = await loadComposer(TWO_PROFILES)
    composer.selectedAgent.value = '900ribu'

    expect(composer.effectiveAgent.value).toBe('900ribu')
    expect(composer.agentChipTooltip.value).toMatch(/agent.*900ribu/i)
  })

  it('resolves to no agent only when neither the session nor the active profile is set', async () => {
    const { composer } = await loadComposer({ ...TWO_PROFILES, active_profile: null })

    expect(composer.effectiveAgent.value).toBeNull()
    expect(composer.agentChipTooltip.value).toMatch(/top-level/i)
  })

  it('resolves to no agent when no profiles are configured at all', async () => {
    const { composer } = await loadComposer({ profiles: {}, active_profile: null })

    expect(composer.availableAgents.value).toEqual([])
    expect(composer.effectiveAgent.value).toBeNull()
  })

  it('marks the active profile as the active one, and only that one', async () => {
    const { composer } = await loadComposer(TWO_PROFILES)

    const names = composer.availableAgents.value.map((p) => p.name)
    expect(names).toEqual(['300 ribu', '900ribu'])
    // The `(active)` badge was `activeAgent` — exactly one profile can carry it.
    expect(composer.activeAgent.value).toBe('300 ribu')
    expect(names.filter((n) => n === composer.activeAgent.value)).toEqual(['300 ribu'])
  })

  it('moves the effective marker with the selection (selected > active > none)', async () => {
    const update = vi.spyOn(api, 'updateSession').mockResolvedValue(undefined as never)
    const { composer } = await loadComposer(TWO_PROFILES)

    // No selection → the active profile is the effective one.
    expect(composer.effectiveAgent.value).toBe('300 ribu')

    // Picking a row is a session update, and it wins the cascade.
    await composer.selectAgent('900ribu')
    expect(update).toHaveBeenCalledWith('sess_cascade', { selectedAgent: '900ribu' })
    expect(composer.effectiveAgent.value).toBe('900ribu')

    // Clearing the selection falls back to the active profile.
    await composer.selectAgent(null)
    expect(update).toHaveBeenLastCalledWith('sess_cascade', { selectedAgent: null })
    expect(composer.effectiveAgent.value).toBe('300 ribu')
  })

  it('falls through a stored selection that names no configured profile', async () => {
    const { composer } = await loadComposer(TWO_PROFILES)
    composer.selectedAgent.value = 'space'

    expect(composer.effectiveAgent.value).toBe('300 ribu')
    expect(composer.agentChipTooltip.value).toMatch(/active agent/i)
  })

  it('resolves to no agent when the active profile names no configured profile', async () => {
    const { composer } = await loadComposer({ ...TWO_PROFILES, active_profile: 'space' })

    expect(composer.effectiveAgent.value).toBeNull()
    expect(composer.agentChipTooltip.value).toMatch(/top-level/i)
  })

  it('resolves a disabled profile, because the backend does not filter on enabled', async () => {
    const { composer } = await loadComposer({
      profiles: {
        '300 ribu': { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1' },
        off: { model: 'MiniMax-M3', base_url: 'https://api.minimax.io/v1', enabled: false },
      },
      active_profile: 'off',
    })

    expect(composer.availableAgents.value.map((p) => p.name)).toEqual(['300 ribu'])
    expect(composer.effectiveAgent.value).toBe('off')
  })
})

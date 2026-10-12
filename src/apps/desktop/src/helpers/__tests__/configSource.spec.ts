import { describe, expect, it } from 'vitest'

import { isWorkspaceAgentSection, WORKSPACE_AGENT_SECTIONS } from '../configSource'

describe('isWorkspaceAgentSection', () => {
  it('accepts every section the workspace settings page renders', () => {
    for (const id of WORKSPACE_AGENT_SECTIONS) expect(isWorkspaceAgentSection(id)).toBe(true)
  })

  it('rejects the user-scope section and unknown ids', () => {
    // `general` is the ONE section left at user scope (decision D4), so a
    // user-scope value must not be shipped as `?section=` to the workspace
    // page.
    expect(isWorkspaceAgentSection('general')).toBe(false)
    expect(isWorkspaceAgentSection('overview')).toBe(false)
    expect(isWorkspaceAgentSection('')).toBe(false)
  })
})

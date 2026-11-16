/** Where a config editor reads and writes its `PabrikConfig`. */
import {
  deleteAgent as apiDeleteAgent,
  deleteWorkspaceAgent,
  getPabrikConfig,
  getWorkspaceConfig,
  savePabrikConfig,
  saveWorkspaceConfig,
  type PabrikConfig,
} from '../api'

export type ConfigScope = 'user' | 'workspace'

/** The config sections that live in Workspace settings, in nav order. */
export const WORKSPACE_AGENT_SECTIONS = ['agents', 'mcp', 'tools', 'evals', 'runtime'] as const

/** Does the WORKSPACE settings page render this section? */
export function isWorkspaceAgentSection(id: string): boolean {
  return (WORKSPACE_AGENT_SECTIONS as readonly string[]).includes(id)
}

export interface PabrikConfigSource {
  /** Which scope this source edits. Drives labels, not requests. */
  readonly scope: ConfigScope
  /** The workspace this source edits, when the scope has one. */
  readonly workspaceId?: string
  /** Load the config to edit. */
  load(): Promise<PabrikConfig>
  /** Persist the whole edited config. */
  save(config: PabrikConfig): Promise<void>
  /** Remove one profile by name. */
  deleteAgent(name: string): Promise<void>
}

export function userConfigSource(): PabrikConfigSource {
  return {
    scope: 'user',
    load: () => getPabrikConfig(),
    save: async (config) => {
      await savePabrikConfig(config)
    },
    deleteAgent: async (name) => {
      await apiDeleteAgent(name)
    },
  }
}

export function workspaceConfigSource(workspaceId: string): PabrikConfigSource {
  return {
    scope: 'workspace',
    workspaceId,
    load: () => getWorkspaceConfig(workspaceId),
    save: async (config) => {
      await saveWorkspaceConfig(workspaceId, config)
    },
    deleteAgent: async (name) => {
      await deleteWorkspaceAgent(workspaceId, name)
    },
  }
}

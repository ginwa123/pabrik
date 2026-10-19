/** Where a config editor reads and writes its `PabrikConfig`. The editor (`PabrikConfigEditor.vue`)
 * used to call the user-scope API functions directly, which made "user settings" and "workspace
 * settings" the same code path with no seam to tell them apart. */
import {
  deleteProfile as apiDeleteProfile,
  deleteWorkspaceProfile,
  getPabrikConfig,
  getWorkspaceConfig,
  savePabrikConfig,
  saveWorkspaceConfig,
  type PabrikConfig,
} from '../api'

export type ConfigScope = 'user' | 'workspace'

/** The config sections that live in Workspace settings, in nav order. One list, two consumers: the
 * settings shell renders a nav item per entry and the workspace view renders an editor for each -
 * so a section can never be listed but unrenderable (a dead link) or renderable but unlisted. */
export const WORKSPACE_AGENT_SECTIONS = ['profiles', 'mcp', 'tools', 'evals'] as const

/**  * Does the WORKSPACE settings page render this section? The complement of
 * `WORKSPACE_AGENT_SECTIONS`, for callers that hold a section id from somewhere else (the editor's
 * remembered tab, a deep link) and must decide whether it has a home in workspace scope at all. */
export function isWorkspaceAgentSection(id: string): boolean {
  return (WORKSPACE_AGENT_SECTIONS as readonly string[]).includes(id)
}

export interface PabrikConfigSource {
  /** Which scope this source edits. Drives labels, not requests. */
  readonly scope: ConfigScope
  /** Load the config to edit. User scope swallows a transport failure into `{}` (pre-existing
   * behaviour: the page still renders defaults). */
  load(): Promise<PabrikConfig>
  /** Persist the whole edited config. */
  save(config: PabrikConfig): Promise<void>
  /** Remove one profile by name. Each scope has its own endpoint: the user-scope one also
   * live-reloads the backend's in-memory config, and the workspace-scope one edits this
   * workspace's own copy and nothing else. */
  deleteProfile(name: string): Promise<void>
}

export function userConfigSource(): PabrikConfigSource {
  return {
    scope: 'user',
    load: () => getPabrikConfig(),
    save: async (config) => {
      await savePabrikConfig(config)
    },
    deleteProfile: async (name) => {
      await apiDeleteProfile(name)
    },
  }
}

export function workspaceConfigSource(workspaceId: string): PabrikConfigSource {
  return {
    scope: 'workspace',
    load: () => getWorkspaceConfig(workspaceId),
    save: async (config) => {
      await saveWorkspaceConfig(workspaceId, config)
    },
    deleteProfile: async (name) => {
      await deleteWorkspaceProfile(workspaceId, name)
    },
  }
}

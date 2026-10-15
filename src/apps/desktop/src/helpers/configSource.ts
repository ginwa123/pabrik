/**
 * Where a config editor reads and writes its `PabrikConfig`.
 *
 * The editor (`PabrikConfigEditor.vue`) used to call the user-scope API
 * functions directly, which made "user settings" and "workspace settings" the
 * same code path with no seam to tell them apart. Two scopes now exist and
 * they are NOT interchangeable:
 *
 *   * `userConfigSource()`      -> `/api/config/pabrik`. Applies everywhere.
 *   * `workspaceConfigSource()` -> `/api/workspaces/:id/config`. Applies to
 *     one workspace, and the server merges it over the user config rather
 *     than replacing it.
 *
 * The difference that matters for the UI is not the URL, it is `scope`: the
 * workspace editor has to render an "Inherited / Overridden" affordance,
 * because a workspace that has overridden nothing is a meaningful state that
 * the user-level editor does not have.
 */
import {
  deleteProfile as apiDeleteProfile,
  getPabrikConfig,
  getWorkspaceConfig,
  savePabrikConfig,
  saveWorkspaceConfig,
  type PabrikConfig,
} from '../api'

export type ConfigScope = 'user' | 'workspace'

/** The config sections that live in Workspace settings, in nav order.
 * One list, two consumers: the settings shell renders a nav item per entry and
 * the workspace view renders an editor for each - so a section can never be
 * listed but unrenderable (a dead link) or renderable but unlisted.
 * `general` is deliberately absent: it is the ONE thing left at user level
 * (decision D4), because it genuinely applies to every workspace. */
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
  /** Load the config to edit.
   * User scope swallows a transport failure into `{}` (pre-existing
   * behaviour: the page still renders defaults). Workspace scope does NOT -
   * it lets the rejection through, and the editor turns that into a visible
   * notification, because "this workspace inherits the user config" and "we
   * could not read this workspace's config" must not render the same way on
   * a page whose whole job is to say which one applies. */
  load(): Promise<PabrikConfig>
  /** Persist the whole edited config. */
  save(config: PabrikConfig): Promise<void>
  /** Remove one profile by name.
   * User scope has a dedicated endpoint (it has to live-reload the backend's
   * in-memory config). Workspace scope does not: the overlay is read per
   * session, so the following `save()` is what actually removes it. Resolving
   * immediately is the honest answer there, and it keeps the editor's
   * optimistic-delete flow identical in both scopes. */
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
    deleteProfile: async () => {
      // See the interface doc: no endpoint, and none is needed.
    },
  }
}

import { apiFetch } from './client'
import type { SkillEvalsRunsResponse, SkillEvalsSummaryResponse } from './sseEvents'

// Skills API A skill is a ROW scoped to one workspace, and that scope is its whole identity: no
// `is_global`, no `cwd`, no `path`. A skill wanted in two workspaces is two rows.
export interface Skill {
  name: string
  description: string
  /** False = the human pinned this skill: every agent write tool refuses it. */
  is_can_auto_improve: boolean
}

/** One SKILL.md frontmatter key that has no column of its own (`origin`, `tags`, `license`, …).
 * Read from the `skill_metadata` table, so nothing has to re-parse the fence in `content`. */
export interface SkillMetadata {
  key: string
  value: string
}

export interface SkillDetail {
  name: string
  description: string
  content: string
  /**    * Companion files stored beside the body (`scripts/…`, `references/…`). `use_skill` materialises
   * them into a temp directory so the body's relative references resolve, so a bundled skill is
   * more than its one row. Zero for a plain single-file skill. */
  asset_count: number
  /** False = the human pinned this skill: every agent write tool refuses it. */
  is_can_auto_improve: boolean
  /** The skill's `skill_metadata`, key-ordered. Empty when the frontmatter carries nothing but
   * `name` and `description`. Editable through `content`: the fence is stored verbatim. */
  metadata: SkillMetadata[]
}

export interface SkillListResponse {
  skills: Skill[]
}

export interface SkillDeleteResponse {
  success: boolean
  skill_name: string
  /** `''` on success; the reason on a refusal. */
  error_message: string
}

/** GET /api/workspaces/:workspaceId/skills */
export async function getSkills(workspaceId: string): Promise<SkillListResponse> {
  return await apiFetch<SkillListResponse>(`/workspaces/${encodeURIComponent(workspaceId)}/skills`)
}

/** GET /api/workspaces/:workspaceId/skills/:skillName */
export async function getSkillDetail(
  workspaceId: string,
  skillName: string,
): Promise<{ skill: SkillDetail | null; error_message: string }> {
  return await apiFetch<{ skill: SkillDetail | null; error_message: string }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
  )
}

/** DELETE /api/workspaces/:workspaceId/skills/:skillName */
export async function deleteSkill(
  workspaceId: string,
  skillName: string,
): Promise<SkillDeleteResponse> {
  return await apiFetch<SkillDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
    { method: 'DELETE' },
  )
}

export interface SkillCreateResponse {
  skill: SkillDetail
}

/** POST /api/workspaces/:workspaceId/skills 201 with the stored row, so the caller can render what
 * it just wrote without a second GET. */
export async function createSkill(
  workspaceId: string,
  input: { name: string; description?: string; content?: string; is_can_auto_improve?: boolean },
): Promise<SkillCreateResponse> {
  return await apiFetch<SkillCreateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills`,
    { method: 'POST', body: input },
  )
}

export interface SkillUpdateResponse {
  skill: SkillDetail
}

/** PATCH /api/workspaces/:workspaceId/skills/:skillName The name is a path param and is IMMUTABLE:
 * a rename would break every `use_skill({ name })` call and every cached `skill_eval` verdict. */
export async function updateSkill(
  workspaceId: string,
  skillName: string,
  input: { description?: string; content?: string; is_can_auto_improve?: boolean },
): Promise<SkillUpdateResponse> {
  return await apiFetch<SkillUpdateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/skills/${encodeURIComponent(skillName)}`,
    { method: 'PATCH', body: input },
  )
}

export async function getSkillEvalsRuns(
  params: {
    run_id?: string
    session_id?: string
    limit?: number
  } = {},
): Promise<SkillEvalsRunsResponse> {
  const q = new URLSearchParams()
  if (params.run_id) q.set('run_id', params.run_id)
  if (params.session_id) q.set('session_id', params.session_id)
  if (params.limit !== undefined) q.set('limit', String(params.limit))
  const suffix = q.toString() ? `?${q.toString()}` : ''
  return await apiFetch<SkillEvalsRunsResponse>(`/skill-evals/runs${suffix}`)
}

export async function getSkillEvalsSummary(sessionId = ''): Promise<SkillEvalsSummaryResponse> {
  const suffix = sessionId ? `?session_id=${encodeURIComponent(sessionId)}` : ''
  return await apiFetch<SkillEvalsSummaryResponse>(`/skill-evals/summary${suffix}`)
}

/** Record that a human accepted a verdict. `result_id` is a QUERY parameter, not a path segment —
 * the backend keeps every route under this prefix a literal so no `:param` route can shadow a later
 * one. */
export async function applySkillEvalResult(
  resultId: string,
  action = 'apply',
): Promise<{
  result_id: string
  skill_name: string
  action: string
  applied: boolean
  message: string
}> {
  const q = new URLSearchParams({ result_id: resultId, action })
  return await apiFetch(`/skill-evals/results/apply?${q.toString()}`, { method: 'POST' })
}

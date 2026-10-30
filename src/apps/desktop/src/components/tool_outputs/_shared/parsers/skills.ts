import {
  asRecord,
  boolField,
  numOrNullField,
  strField,
  strOrNullField,
  unwrapDataRecord,
} from './internal'

/** The name a skill tool acted on. `skill_name` is the canonical field on every skill tool payload;
 * `name` is the echo of what was requested and is absent from some rows. */
function skillNameField(o: Record<string, unknown>): string {
  const primary = strOrNullField(o, 'skill_name')
  if (primary !== null && primary.trim() !== '') return primary
  return strField(o, 'name')
}

export interface ParsedEditSkill {
  skillName: string
  edited: boolean
  success: boolean
  error: string | null
}

export function parseEditSkill(data: unknown): ParsedEditSkill {
  const o = unwrapDataRecord(data)
  const edited = boolField(o, 'edited', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    edited,
    success: error === null,
    error,
  }
}

export interface ParsedAddSkill {
  skillName: string
  created: boolean
  success: boolean
  error: string | null
}

export function parseAddSkill(data: unknown): ParsedAddSkill {
  const o = unwrapDataRecord(data)
  const created = boolField(o, 'created', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    created,
    success: error === null,
    error,
  }
}

export interface ParsedRemoveSkill {
  skillName: string
  removed: boolean
  success: boolean
  error: string | null
}

export function parseRemoveSkill(data: unknown): ParsedRemoveSkill {
  const o = unwrapDataRecord(data)
  const removed = boolField(o, 'removed', false)
  const error = strOrNullField(o, 'error')
  return {
    skillName: skillNameField(o),
    removed,
    success: error === null,
    error,
  }
}

/** One row of a `search_skills` page. Identity is the name ALONE: the page is one workspace's
 * skills, so there is no tier to tag and no path to hand back. */
export interface SkillSearchRow {
  name: string
  description: string
}

/** `search_skills` result. */
export interface ParsedSearchSkills {
  query: string
  patternMode: string | null
  patternWarning: string | null
  count: number
  total: number
  offset: number | null
  limit: number | null
  skills: SkillSearchRow[]
  truncated: boolean
  nextOffset: number | null
  hint: string | null
}

function parseSkillRecord(item: unknown): SkillSearchRow | null {
  const r = asRecord(item)
  const name = strField(r, 'name')
  if (!name) return null
  return {
    name,
    description: strField(r, 'description'),
  }
}

export function parseSearchSkills(data: unknown): ParsedSearchSkills {
  const o = unwrapDataRecord(data)
  const skills: SkillSearchRow[] = []
  const skillsRaw = Array.isArray(o.skills) ? o.skills : []
  for (const item of skillsRaw) {
    const row = parseSkillRecord(item)
    if (row) skills.push(row)
  }
  return {
    query: strField(o, 'query'),
    patternMode: strOrNullField(o, 'pattern_mode'),
    patternWarning: strOrNullField(o, 'pattern_warning'),
    count: numOrNullField(o, 'count') ?? skills.length,
    total: numOrNullField(o, 'total') ?? skills.length,
    offset: numOrNullField(o, 'offset'),
    limit: numOrNullField(o, 'limit'),
    skills,
    truncated: boolField(o, 'truncated', false),
    nextOffset: numOrNullField(o, 'next_offset'),
    hint: strOrNullField(o, 'hint'),
  }
}

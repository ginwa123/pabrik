/** The Skills settings list's filter + sort, as pure functions: the
 * behaviour behind the search box, the facet chips and the sort menu.
 * Mirrors the `Skill` row shape from `api/index.ts`. */
export interface SkillRow {
  name: string
  description: string
  is_can_auto_improve: boolean
}

/** The facets the list can narrow by. Every one is a real column. */
export type SkillFacet = 'auto_improve' | 'pinned'

export type SkillSort = 'name' | 'updated' | 'auto_improve'

export interface SkillFilterState {
  query: string
  facets: SkillFacet[]
  sort: SkillSort
}

export const EMPTY_FILTER_STATE: SkillFilterState = {
  query: '',
  facets: [],
  sort: 'name',
}

/** True when nothing is being asked for, so the list is the raw list. */
export function isFilterActive(state: SkillFilterState): boolean {
  return state.query.trim().length > 0 || state.facets.length > 0
}

/** Case-insensitive substring match on name and description. Every term
 * must match somewhere (AND), so "zig test" narrows rather than widens. */
export function matchesQuery(row: SkillRow, query: string): boolean {
  const terms = query
    .toLowerCase()
    .split(/\s+/)
    .filter((t) => t.length > 0)
  if (terms.length === 0) return true
  const name = row.name.toLowerCase()
  const description = row.description.toLowerCase()
  return terms.every((term) => name.includes(term) || description.includes(term))
}

/** One facet, one predicate. `pinned` is the inverse of auto-improve. */
export function matchesFacet(row: SkillRow, facet: SkillFacet): boolean {
  if (facet === 'auto_improve') return row.is_can_auto_improve
  return !row.is_can_auto_improve
}

/** Narrow by query and facets. Facets are OR within themselves and AND
 * with the query, which is what a row of toggle chips means elsewhere. */
export function filterSkills(rows: SkillRow[], state: SkillFilterState): SkillRow[] {
  const query = state.query.trim()
  const facets = state.facets
  if (query.length === 0 && facets.length === 0) return rows
  return rows.filter((row) => {
    if (query.length > 0 && !matchesQuery(row, query)) return false
    if (facets.length > 0 && !facets.some((f) => matchesFacet(row, f))) return false
    return true
  })
}

/** Order the rows. `name` is the backend's own `ORDER BY name`, so it is
 * the default. `numeric: true` puts `skill-2` before `skill-10`. */
export function sortSkills(rows: SkillRow[], sort: SkillSort): SkillRow[] {
  if (sort === 'name') return rows
  const out = rows.slice()
  if (sort === 'auto_improve') {
    // Editable first: the rows an agent may rewrite are worth scanning.
    out.sort((a, b) => {
      if (a.is_can_auto_improve !== b.is_can_auto_improve) {
        return a.is_can_auto_improve ? -1 : 1
      }
      return a.name.localeCompare(b.name, undefined, { numeric: true })
    })
    return out
  }
  // `updated` is not on the list wire, so it falls back to name order.
  out.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
  return out
}

/** Filter then sort — the one call the component makes. */
export function selectVisibleSkills(rows: SkillRow[], state: SkillFilterState): SkillRow[] {
  return sortSkills(filterSkills(rows, state), state.sort)
}

/** How many of the LOADED rows the query and facets leave. The list wire
 * has no total, so this must not claim to be a workspace-wide count. */
export function countVisible(rows: SkillRow[], state: SkillFilterState): number {
  return filterSkills(rows, state).length
}

/** Encode the filter state for the URL. Empty and default values are
 * omitted, so a default view leaves a clean URL — the rule `KanbanView`
 * applies to `?sorts=` and `?layout=`. */
export function encodeSkillFilter(state: SkillFilterState): Record<string, string> {
  const out: Record<string, string> = {}
  const query = state.query.trim()
  if (query.length > 0) out.q = query
  if (state.facets.length > 0) out.facet = state.facets.join(',')
  if (state.sort !== 'name') out.sort = state.sort
  return out
}

/** Parse the URL back into filter state. Unknown values are dropped: a
 * hand-edited `?sort=banana` must not reach a state no button produced. */
export function decodeSkillFilter(query: Record<string, unknown>): SkillFilterState {
  const readOne = (key: string): string => {
    const raw = query?.[key]
    if (typeof raw === 'string') return raw
    if (Array.isArray(raw)) {
      const first = raw.find((v): v is string => typeof v === 'string')
      return first ?? ''
    }
    return ''
  }

  const facets = readOne('facet')
    .split(',')
    .map((f) => f.trim())
    .filter((f): f is SkillFacet => f === 'auto_improve' || f === 'pinned')

  const sort = readOne('sort')
  return {
    query: readOne('q'),
    facets,
    sort: sort === 'updated' || sort === 'auto_improve' ? sort : 'name',
  }
}

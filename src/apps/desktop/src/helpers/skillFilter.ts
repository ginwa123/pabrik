/*
 * The Skills settings list's filter + sort, as pure functions.
 *
 * The list is a wall of 41 identical cards on this machine, and the only
 * way to find one is to read every description. These functions are the
 * behaviour behind the search box, the facet chips and the sort menu, kept
 * out of the component so they can be tested without mounting anything.
 *
 * Two rules the component relies on:
 *
 * 1. A query is matched against the NAME and the DESCRIPTION, never the
 *    body. The body is not on the list wire (`Skill` has no `content`),
 *    so matching it would mean a second request per keystroke.
 * 2. An empty query is "no filter", not "match nothing". The same is true
 *    of an empty facet set. `filterSkills` therefore returns the input
 *    slice untouched when nothing is being asked for.
 */

/** The list-row shape. Mirrors `Skill` from `api/index.ts`. */
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

/**
 * Case-insensitive substring match on name and description.
 *
 * Every whitespace-separated term must match somewhere (AND), so
 * "zig test" finds the skill about Zig tests and not every skill that
 * mentions either word. A term may match the name while another matches
 * the description.
 */
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

/**
 * Narrow by query and facets. Facets are OR within themselves (a row in
 * either facet passes) and AND with the query, which is what a row of
 * toggle chips means everywhere else in this app.
 */
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

/**
 * Order the rows. `name` is the backend's own `ORDER BY name`, so it is
 * the default and the only order that needs no extra column.
 *
 * `localeCompare` with `numeric: true` so `skill-2` sorts before
 * `skill-10`; plain `<` on strings puts `skill-10` first.
 */
export function sortSkills(rows: SkillRow[], sort: SkillSort): SkillRow[] {
  if (sort === 'name') return rows
  const out = rows.slice()
  if (sort === 'auto_improve') {
    // Editable first: the rows an agent may rewrite are the ones worth
    // scanning, and the pinned ones are the ones you must not touch by
    // accident.
    out.sort((a, b) => {
      if (a.is_can_auto_improve !== b.is_can_auto_improve) {
        return a.is_can_auto_improve ? -1 : 1
      }
      return a.name.localeCompare(b.name, undefined, { numeric: true })
    })
    return out
  }
  // `updated` is not a column on the list wire, so it falls back to name
  // order rather than pretending to know an order it cannot see.
  out.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }))
  return out
}

/** Filter then sort — the one call the component makes. */
export function selectVisibleSkills(rows: SkillRow[], state: SkillFilterState): SkillRow[] {
  return sortSkills(filterSkills(rows, state), state.sort)
}

/**
 * The count shown beside the search box: how many of the loaded rows the
 * current query and facets leave. It is a count of LOADED rows, not of
 * every skill in the workspace — the list wire has no total, and a number
 * that claims otherwise would be a lie the user cannot detect.
 */
export function countVisible(rows: SkillRow[], state: SkillFilterState): number {
  return filterSkills(rows, state).length
}

/**
 * Encode the filter state for the URL. `?q=` and `?facet=` are omitted
 * when empty so a default view leaves a clean URL, and `sort` is omitted
 * when it is the default — the same rule `KanbanView` applies to
 * `?sorts=` and `?layout=`.
 */
export function encodeSkillFilter(state: SkillFilterState): Record<string, string> {
  const out: Record<string, string> = {}
  const query = state.query.trim()
  if (query.length > 0) out.q = query
  if (state.facets.length > 0) out.facet = state.facets.join(',')
  if (state.sort !== 'name') out.sort = state.sort
  return out
}

/**
 * Parse the URL back into filter state. Unknown values are dropped rather
 * than trusted: a hand-edited `?sort=banana` must not put the menu in a
 * state no button produced.
 */
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

/** skillFilter.ts — the behaviour behind the Skills
 * settings search box, facet chips and sort
 * menu. Pure functions, so nothing needs injecting. */
import { describe, expect, it } from 'vitest'
import {
  countVisible,
  decodeSkillFilter,
  EMPTY_FILTER_STATE,
  encodeSkillFilter,
  filterSkills,
  isFilterActive,
  matchesQuery,
  selectVisibleSkills,
  sortSkills,
  type SkillFilterState,
  type SkillRow,
} from '../skillFilter'

const ROWS: SkillRow[] = [
  {
    name: 'behavior-unit-tests',
    description: 'Write deterministic unit tests',
    is_can_auto_improve: false,
  },
  {
    name: 'zig-build-test-sharding',
    description: 'Split a slow zig build test',
    is_can_auto_improve: true,
  },
  {
    name: 'zig-test-runner-fails',
    description: 'A runner that logs errors',
    is_can_auto_improve: true,
  },
  {
    name: 'verify-html-wireframe',
    description: 'Assert DOM geometry in a browser',
    is_can_auto_improve: true,
  },
  {
    name: 'design-taste-frontend',
    description: 'Art direction for websites',
    is_can_auto_improve: false,
  },
]

const state = (over: Partial<SkillFilterState> = {}): SkillFilterState => ({
  ...EMPTY_FILTER_STATE,
  ...over,
})

describe('matching a query', () => {
  it('matches the name case-insensitively', () => {
    expect(matchesQuery(ROWS[0], 'BEHAVIOR')).toBe(true)
    expect(matchesQuery(ROWS[0], 'behavior')).toBe(true)
  })

  it('matches the description, not only the name', () => {
    expect(matchesQuery(ROWS[3], 'geometry')).toBe(true)
  })

  it('returns every row for an empty or whitespace query', () => {
    expect(matchesQuery(ROWS[0], '')).toBe(true)
    expect(matchesQuery(ROWS[0], '   ')).toBe(true)
  })

  it('requires every term to match somewhere, so two words narrow', () => {
    // "zig" alone hits two rows; "zig build" hits one.
    expect(ROWS.filter((r) => matchesQuery(r, 'zig')).length).toBe(2)
    expect(ROWS.filter((r) => matchesQuery(r, 'zig build')).length).toBe(1)
  })

  it('lets one term match the name and another the description', () => {
    expect(matchesQuery(ROWS[1], 'zig slow')).toBe(true)
  })

  it('does not match a term that appears in neither field', () => {
    expect(matchesQuery(ROWS[0], 'kubernetes')).toBe(false)
  })
})

describe('filtering by facet', () => {
  it('keeps only the rows an agent may rewrite under auto_improve', () => {
    const out = filterSkills(ROWS, state({ facets: ['auto_improve'] }))
    expect(out.map((r) => r.name)).toEqual([
      'zig-build-test-sharding',
      'zig-test-runner-fails',
      'verify-html-wireframe',
    ])
  })

  it('keeps only the human-pinned rows under pinned', () => {
    const out = filterSkills(ROWS, state({ facets: ['pinned'] }))
    expect(out.map((r) => r.name)).toEqual(['behavior-unit-tests', 'design-taste-frontend'])
  })

  it('treats two facets as OR, so both groups survive', () => {
    const out = filterSkills(ROWS, state({ facets: ['auto_improve', 'pinned'] }))
    expect(out.length).toBe(ROWS.length)
  })

  it('returns the input untouched when no facet and no query are set', () => {
    expect(filterSkills(ROWS, state())).toBe(ROWS)
  })
})

describe('combining a query with facets', () => {
  it('ANDs the query with the facet', () => {
    const out = filterSkills(ROWS, state({ query: 'zig', facets: ['auto_improve'] }))
    expect(out.map((r) => r.name)).toEqual(['zig-build-test-sharding', 'zig-test-runner-fails'])
  })

  it('returns nothing when the query and the facet disagree', () => {
    const out = filterSkills(ROWS, state({ query: 'zig', facets: ['pinned'] }))
    expect(out).toEqual([])
  })

  it('ignores surrounding whitespace in the query', () => {
    expect(filterSkills(ROWS, state({ query: '  zig  ' })).length).toBe(2)
  })
})

describe('sorting', () => {
  it('leaves name order alone, because the backend already sorted', () => {
    expect(sortSkills(ROWS, 'name')).toBe(ROWS)
  })

  it('puts the editable rows first under auto_improve, then names them', () => {
    const out = sortSkills(ROWS, 'auto_improve')
    expect(out.map((r) => r.name)).toEqual([
      'verify-html-wireframe',
      'zig-build-test-sharding',
      'zig-test-runner-fails',
      'behavior-unit-tests',
      'design-taste-frontend',
    ])
  })

  it('orders digits numerically, so skill-2 comes before skill-10', () => {
    const rows: SkillRow[] = [
      { name: 'skill-10', description: '', is_can_auto_improve: true },
      { name: 'skill-2', description: '', is_can_auto_improve: true },
    ]
    expect(sortSkills(rows, 'auto_improve').map((r) => r.name)).toEqual(['skill-2', 'skill-10'])
  })

  it('does not mutate the input slice', () => {
    const before = ROWS.map((r) => r.name)
    sortSkills(ROWS, 'auto_improve')
    expect(ROWS.map((r) => r.name)).toEqual(before)
  })
})

describe('the visible list', () => {
  it('filters and then sorts', () => {
    const out = selectVisibleSkills(ROWS, state({ query: 'zig', sort: 'auto_improve' }))
    expect(out.map((r) => r.name)).toEqual(['zig-build-test-sharding', 'zig-test-runner-fails'])
  })

  it('is the whole list when nothing is asked for', () => {
    expect(selectVisibleSkills(ROWS, state())).toBe(ROWS)
  })
})

describe('the count beside the search box', () => {
  it('counts the rows the query leaves', () => {
    expect(countVisible(ROWS, state({ query: 'zig' }))).toBe(2)
  })

  it('counts every loaded row when nothing is asked for', () => {
    expect(countVisible(ROWS, state())).toBe(ROWS.length)
  })

  it('is zero for a query that matches nothing', () => {
    expect(countVisible(ROWS, state({ query: 'kubernetes' }))).toBe(0)
  })
})

describe('whether a filter is active', () => {
  it('is false for the default state', () => {
    expect(isFilterActive(state())).toBe(false)
  })

  it('is true for a query, even a whitespace-only one being typed', () => {
    expect(isFilterActive(state({ query: 'a' }))).toBe(true)
  })

  it('is true for a facet with no query', () => {
    expect(isFilterActive(state({ facets: ['pinned'] }))).toBe(true)
  })
})

describe('the URL round trip', () => {
  it('writes nothing for the default state, so the URL stays clean', () => {
    expect(encodeSkillFilter(state())).toEqual({})
  })

  it('writes q, facet and sort when they differ from the default', () => {
    expect(
      encodeSkillFilter(state({ query: 'zig', facets: ['pinned'], sort: 'auto_improve' })),
    ).toEqual({ q: 'zig', facet: 'pinned', sort: 'auto_improve' })
  })

  it('trims the query it writes', () => {
    expect(encodeSkillFilter(state({ query: '  zig  ' }))).toEqual({ q: 'zig' })
  })

  it('reads back what it wrote', () => {
    const encoded = encodeSkillFilter(
      state({ query: 'zig', facets: ['auto_improve'], sort: 'updated' }),
    )
    expect(decodeSkillFilter(encoded)).toEqual({
      query: 'zig',
      facets: ['auto_improve'],
      sort: 'updated',
    })
  })

  it('drops an unknown sort rather than trusting it', () => {
    expect(decodeSkillFilter({ sort: 'banana' }).sort).toBe('name')
  })

  it('drops an unknown facet rather than trusting it', () => {
    expect(decodeSkillFilter({ facet: 'banana' }).facets).toEqual([])
  })

  it('keeps a known facet and drops the unknown one beside it', () => {
    expect(decodeSkillFilter({ facet: 'pinned,banana' }).facets).toEqual(['pinned'])
  })

  it('reads the first value when the router hands back an array', () => {
    expect(decodeSkillFilter({ q: ['zig', 'other'] }).query).toBe('zig')
  })

  it('survives an absent query object', () => {
    expect(decodeSkillFilter({})).toEqual(EMPTY_FILTER_STATE)
  })
})

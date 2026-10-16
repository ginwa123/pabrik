/** SearchSkills.vue — the `search_skills` card. Pins the paged-search result shape: flat `skills[]`
 * rows of `name` / `description` only, plus `count`/`total`/`offset`/`limit`/`truncated`/
 * `next_offset`/`pattern_warning`. */
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import SearchSkills from '../SearchSkills.vue'

const page = {
  query: 'auth',
  pattern_mode: 'regex',
  pattern_warning: null,
  count: 2,
  total: 7,
  offset: 0,
  limit: 2,
  skills: [
    { name: 'auth', description: 'handles auth' },
    { name: 'auth-notes', description: 'secondary auth notes' },
  ],
  truncated: true,
  next_offset: 2,
  hint: 'Showing 0-2 of 7 matches — call again with offset=2 (same query) for the next page, or narrow the query.',
}

const rowNames = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="search-skills-row"]').map((r) => r.attributes('data-skill-name'))

describe('SearchSkills.vue — header names the tool and the paging facts', () => {
  it('renders search_skills with the count-of-total and the next offset', () => {
    const wrapper = mount(SearchSkills, {
      props: { content: page, expanded: true } as never,
    })
    const text = wrapper.text()
    expect(text).toContain('search_skills')
    expect(text).toContain('2/7 skills')
    expect(text).toContain('next offset 2')
    // The hint (which names the offset for the next page) is rendered too.
    expect(text).toContain('Showing 0-2 of 7 matches')
  })

  it('renders one flat row per skill with its description', () => {
    const wrapper = mount(SearchSkills, { props: { content: page, expanded: true } as never })
    const rows = wrapper.findAll('[data-testid="search-skills-row"]')
    expect(rows).toHaveLength(2)
    expect(rows.at(0)?.text()).toContain('auth')
    expect(rows.at(0)?.text()).toContain('handles auth')
    // Neither the two-tier sections nor the per-row badge survive.
    expect(wrapper.text()).not.toContain('Global Skills')
    expect(wrapper.text()).not.toContain('Local Skills')
    expect(wrapper.find('[data-testid="search-skills-scope"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('global')
    expect(wrapper.text()).not.toContain('local')
  })

  it('never renders a path, and keys each row by its name alone', () => {
    const wrapper = mount(SearchSkills, { props: { content: page, expanded: true } as never })
    expect(wrapper.text()).not.toContain('SKILL.MD')
    expect(rowNames(wrapper)).toEqual(['auth', 'auth-notes'])
  })

  it('still renders names from a payload carrying the retired scope / path keys', () => {
    // A transcript recorded before the table refactor. The rows must not
    // collapse to blanks just because the extra keys are gone.
    const legacy = {
      ...page,
      skills: [
        { name: 'auth', description: 'handles auth', scope: 'global', path: '/g/SKILL.MD' },
        { name: 'auth-notes', description: 'secondary notes', scope: 'local', path: '/l/SK.MD' },
      ],
    }
    const wrapper = mount(SearchSkills, { props: { content: legacy, expanded: true } as never })
    const rows = wrapper.findAll('[data-testid="search-skills-row"]')
    expect(rows).toHaveLength(2)
    expect(rows.at(0)?.text()).toContain('handles auth')
    expect(rowNames(wrapper)).toEqual(['auth', 'auth-notes'])
    expect(wrapper.text()).not.toContain('/g/SKILL.MD')
    expect(wrapper.find('[data-testid="search-skills-scope"]').exists()).toBe(false)
  })

  it('renders a row whose description is empty', () => {
    const wrapper = mount(SearchSkills, {
      props: {
        content: { ...page, skills: [{ name: 'bare', description: '' }], count: 1, total: 1 },
        expanded: true,
      } as never,
    })
    const row = wrapper.find('[data-testid="search-skills-row"]')
    expect(row.exists()).toBe(true)
    expect(row.text()).toContain('bare')
  })
})

describe('SearchSkills.vue — warnings and empty states', () => {
  it('surfaces a non-null pattern_warning', () => {
    const wrapper = mount(SearchSkills, {
      props: {
        content: {
          ...page,
          query: 'foo(',
          pattern_mode: 'literal_fallback',
          pattern_warning: 'unbalanced ( — matched as a literal',
          truncated: false,
          next_offset: null,
        },
        expanded: true,
      } as never,
    })
    expect(wrapper.find('[data-testid="search-skills-warning"]').text()).toContain(
      'unbalanced ( — matched as a literal',
    )
  })

  it('renders no warning block when pattern_warning is null', () => {
    const wrapper = mount(SearchSkills, { props: { content: page, expanded: true } as never })
    expect(wrapper.find('[data-testid="search-skills-warning"]').exists()).toBe(false)
  })

  it('distinguishes "no match" from "no skills installed" by query emptiness', () => {
    const noMatch = mount(SearchSkills, {
      props: {
        content: { ...page, skills: [], count: 0, total: 0, hint: '' },
        expanded: true,
      } as never,
    })
    expect(noMatch.find('[data-testid="search-skills-empty"]').text()).toContain(
      'No skills match "auth"',
    )

    const noneInstalled = mount(SearchSkills, {
      props: {
        content: { ...page, query: '', skills: [], count: 0, total: 0, hint: '' },
        expanded: true,
      } as never,
    })
    expect(noneInstalled.find('[data-testid="search-skills-empty"]').text()).toContain(
      'No skills installed',
    )
  })

  it('does not throw on missing / empty data', () => {
    const wrapper = mount(SearchSkills, { props: { content: undefined, expanded: true } as never })
    expect(wrapper.findAll('[data-testid="search-skills-row"]')).toHaveLength(0)
    expect(wrapper.text()).toContain('search_skills')
  })

  it('does not throw when skills holds non-objects', () => {
    const wrapper = mount(SearchSkills, {
      props: { content: { query: 'x', skills: ['auth', null, 7] }, expanded: true } as never,
    })
    expect(wrapper.findAll('[data-testid="search-skills-row"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="search-skills-empty"]').exists()).toBe(true)
  })
})

describe('SearchSkills.vue — success with args shows Arguments when expanded', () => {
  it('expanded body shows Arguments', () => {
    const wrapper = mount(SearchSkills, {
      props: {
        content: { query: 'all', skills: [], count: 0, total: 0, hint: '' },
        parameters: '{"query":"all"}',
        expanded: true,
      } as never,
    })
    expect(wrapper.text()).toContain('Arguments')
  })
})

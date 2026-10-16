/** Tests for SetGitWorktree.vue — the tool_output component that renders the XML response from the
 * `set_git_worktree` agent tool. The component is purely presentational (no API calls), so no mocks
 * are needed. Mirrors the AddSkill/RemoveSkill tool_output style. */
import { mount } from '@vue/test-utils'
import { afterEach, describe, expect, it } from 'vitest'

import SetGitWorktree from '../components/tool_outputs/SetGitWorktree.vue'

const SET_SUCCESS = {
  created: true,
  path: '/abs/.worktrees/auth-fix',
  branch: 'worktree/auth-fix',
  error: null,
}

const CLEAR_SUCCESS = { cleared: true, error: null }

const ERROR_XML = { created: false, error: 'path is required (or pass clear=true)' }

const PATH_ONLY = { created: true, path: '/tmp/x', error: null }

describe('SetGitWorktree', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the basename of the path in the header on SET success', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: SET_SUCCESS, expanded: false },
    })
    expect(wrapper.text()).toContain('auth-fix')
    expect(wrapper.text()).toContain('set_git_worktree')
  })

  it('shows the ✓ status indicator on SET success', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: SET_SUCCESS },
    })
    expect(wrapper.text()).toContain('✓')
    expect(wrapper.text()).not.toContain('✗')
  })

  it('shows the ✗ status indicator on error', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: ERROR_XML },
    })
    expect(wrapper.text()).toContain('✗')
  })

  it('renders "(cleared)" in the header on CLEAR success', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: CLEAR_SUCCESS },
    })
    expect(wrapper.text()).toContain('(cleared)')
    expect(wrapper.text()).toContain('✓')
  })

  it('expands to show the full path and branch when clicked', async () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: SET_SUCCESS, expanded: false },
    })
    expect(wrapper.text()).not.toContain('Branch:')

    // Click the header to expand
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('/abs/.worktrees/auth-fix')
    expect(wrapper.text()).toContain('Branch:')
    expect(wrapper.text()).toContain('worktree/auth-fix')
  })

  it('renders the error message in the expanded body', async () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: ERROR_XML, expanded: true },
    })
    expect(wrapper.text()).toContain('Error:')
    expect(wrapper.text()).toContain('path is required (or pass clear=true)')
  })

  it('auto-expands when expanded prop is true', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: SET_SUCCESS, expanded: true },
    })
    expect(wrapper.text()).toContain('Branch:')
    expect(wrapper.text()).toContain('/abs/.worktrees/auth-fix')
  })

  it('handles a path with no branch element (PATH_ONLY)', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: PATH_ONLY, expanded: true },
    })
    expect(wrapper.text()).toContain('/tmp/x')
    // Branch line should not be present when no <branch> tag is in the XML
    expect(wrapper.text()).not.toContain('Branch:')
  })

  it('renders the CLEAR status text in the expanded body', async () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: CLEAR_SUCCESS, expanded: false },
    })
    await wrapper.find('[role="button"]').trigger('click')
    expect(wrapper.text()).toContain('Worktree binding removed and directory deleted.')
  })

  it('draws no icon at all, unlike the components that lead with one', () => {
    wrapper = mount(SetGitWorktree, {
      props: { content: SET_SUCCESS },
    })
    // `UiIcon` stamps every icon it renders with data-testid="ui-icon",
    // so one assertion covers every glyph instead of a per-emoji blacklist
    // that goes stale the moment someone adds a name to the registry.
    expect(wrapper.find('[data-testid="ui-icon"]').exists()).toBe(false)
    expect(wrapper.find('[data-icon="tree"]').exists()).toBe(false)
  })
})

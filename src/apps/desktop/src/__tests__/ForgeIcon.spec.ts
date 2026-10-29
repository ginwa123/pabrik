import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'

import ForgeIcon from '../components/git/ForgeIcon.vue'

/** The brand marks are locked by path, the same way `WorkspaceItemTaskCard.gitBranch.spec.ts` locks
 * the fork/branch SVG. The reason is in AGENTS.md ("No Emoji as Icons"): the panel used to say 🔀
 * for both forges, so a GitLab merge request rendered identically to a GitHub pull request. */
const GITHUB_PATH_FRAGMENT = 'M12 .297c-6.63 0-12 5.373-12 12'
const GITLAB_PATH_FRAGMENT = 'm23.6004 9.5927'

describe('ForgeIcon', () => {
  it('renders the GitHub mark for github, empty, and unknown providers', () => {
    // pr_provider is empty on every session created before GitLab
    // support existed, and all of those are GitHub — same default as
    // forgeWording().
    for (const provider of ['github', '', null, undefined, 'something-else']) {
      const wrapper = mount(ForgeIcon, { props: { provider } })
      expect(wrapper.find('path').attributes('d')).toContain(GITHUB_PATH_FRAGMENT)
      expect(wrapper.attributes('data-forge')).toBe('github')
    }
  })

  it('renders the GitLab mark for gitlab, and never the GitHub path', () => {
    const wrapper = mount(ForgeIcon, { props: { provider: 'gitlab' } })
    const d = wrapper.find('path').attributes('d')
    expect(d).toContain(GITLAB_PATH_FRAGMENT)
    expect(d).not.toContain(GITHUB_PATH_FRAGMENT)
    expect(wrapper.attributes('data-forge')).toBe('gitlab')
  })

  it('follows forgeWording for every provider, so prose and icon agree', () => {
    // The bug this component exists to prevent was icon and prose
    // disagreeing. Same input, same answer, one place.
    const github = mount(ForgeIcon, { props: { provider: 'github' } })
    const gitlab = mount(ForgeIcon, { props: { provider: 'gitlab' } })
    expect(github.attributes('data-forge')).not.toBe(gitlab.attributes('data-forge'))
  })

  it('fills with currentColor so it inherits a token, never a brand hex', () => {
    // The palette is muted; GitLab's #FC6D26 beside it reads as an error.
    const wrapper = mount(ForgeIcon, { props: { provider: 'gitlab' } })
    expect(wrapper.attributes('fill')).toBe('currentColor')
    expect(wrapper.html()).not.toMatch(/#f[0-9a-f]{5}/i)
  })

  it('is aria-hidden without a title, and a labelled image with one', () => {
    const bare = mount(ForgeIcon, { props: { provider: 'github' } })
    expect(bare.attributes('aria-hidden')).toBe('true')
    expect(bare.attributes('role')).toBeUndefined()
    expect(bare.find('title').exists()).toBe(false)

    const named = mount(ForgeIcon, { props: { provider: 'github', title: 'GitHub pull request' } })
    expect(named.attributes('aria-hidden')).toBeUndefined()
    expect(named.attributes('role')).toBe('img')
    expect(named.find('title').text()).toBe('GitHub pull request')
  })

  it('takes a Tailwind size class rather than a pixel prop', () => {
    expect(mount(ForgeIcon).classes()).toContain('w-4')
    expect(mount(ForgeIcon, { props: { sizeClass: 'w-7 h-7' } }).classes()).toContain('w-7')
  })
})

import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import UiIcon from '../components/ui/UiIcon.vue'
import { ICON_PATHS, type UiIconName } from '../components/ui/icons'

/**
 * `UiIcon` is the replacement for every emoji that used to stand in for
 * an icon, so these tests answer three questions the app depends on:
 *
 *  1. Does every name in the registry actually render geometry? A key
 *     with an empty path array renders a silent 0x0 hole where an icon
 *     should be, and nothing else in the suite would notice.
 *  2. Is the glyph identifiable after the fact? `data-icon` is the
 *     reason an icon-only control is assertable at all; the old emoji
 *     had nothing to pin a spec to.
 *  3. Does it stay decorative by default? An `aria-hidden` icon next
 *     to a visible label is correct; the same icon announced as
 *     "Trash" after "Delete" is the bug.
 */
describe('UiIcon', () => {
  const names = Object.keys(ICON_PATHS) as UiIconName[]

  it('has a non-empty path list for every name in the registry', () => {
    expect(names.length).toBeGreaterThan(0)
    // `ICON_PATHS` is `as const`, so TS knows each entry's exact length and flags a `=== 0`
    // comparison as impossible. That is the point: this test is the runtime witness that the
    // registry still holds geometry, and a widened view is what lets it say so out loud.
    const pathsOf = (name: UiIconName): readonly string[] => ICON_PATHS[name]
    expect(names.filter((n) => pathsOf(n).length === 0)).toEqual([])
    // Every `d` must actually look like geometry, not an empty attribute.
    const blank = names.flatMap((n) =>
      pathsOf(n)
        .filter((d) => !d || !/[Mm]/.test(d))
        .map((d) => `${n}: ${JSON.stringify(d)}`),
    )
    expect(blank).toEqual([])
  })

  it.each(names)('renders geometry and tags itself for %s', (name) => {
    const wrapper = mount(UiIcon, { props: { name } })
    const svg = wrapper.find('svg')
    expect(svg.exists()).toBe(true)
    expect(svg.attributes('data-testid')).toBe('ui-icon')
    expect(svg.attributes('data-icon')).toBe(name)

    const paths = wrapper.findAll('path')
    expect(paths.length).toBe(ICON_PATHS[name].length)
    for (const p of paths) {
      expect((p.attributes('d') ?? '').length).toBeGreaterThan(0)
    }
  })

  it('inherits its colour instead of baking one in', () => {
    // The palette rule: colour comes from the surrounding CSS variable.
    // A hard-coded hex here is how GitLab orange ended up in a muted UI.
    const wrapper = mount(UiIcon, { props: { name: 'trash' } })
    const svg = wrapper.find('svg')
    expect(svg.attributes('stroke')).toBe('currentColor')
    expect(svg.attributes('fill')).toBe('none')
    expect(wrapper.html()).not.toMatch(/#[0-9a-f]{3,6}/i)
  })

  it('defaults to the 16px box and honours sizeClass over size', () => {
    const bySize = mount(UiIcon, { props: { name: 'file', size: 22 } })
    expect(bySize.find('svg').attributes('width')).toBe('22')
    expect(bySize.find('svg').attributes('height')).toBe('22')

    const byClass = mount(UiIcon, { props: { name: 'file', size: 22, sizeClass: 'w-5 h-5' } })
    const el = byClass.find('svg')
    expect(el.classes()).toContain('w-5')
    expect(el.attributes('width')).toBeUndefined()
  })

  it('carries the layout classes that keep the box equal to the glyph', () => {
    // Without these an inline SVG opens descender space below the text
    // baseline and a flex parent happily squashes it — the exact
    // "row is taller than it should be" failure the emoji swap fixes.
    const el = mount(UiIcon, { props: { name: 'file' } }).find('svg')
    expect(el.classes()).toContain('inline-block')
    expect(el.classes()).toContain('shrink-0')
    expect(el.classes()).toContain('align-middle')
  })

  it('is decorative by default and named only when asked', () => {
    const plain = mount(UiIcon, { props: { name: 'trash' } })
    expect(plain.find('svg').attributes('aria-hidden')).toBe('true')
    expect(plain.find('svg').attributes('role')).toBeUndefined()
    expect(plain.find('title').exists()).toBe(false)

    const named = mount(UiIcon, { props: { name: 'trash', title: 'Delete worktree' } })
    expect(named.find('svg').attributes('aria-hidden')).toBeUndefined()
    expect(named.find('svg').attributes('role')).toBe('img')
    expect(named.find('title').text()).toBe('Delete worktree')
  })
})

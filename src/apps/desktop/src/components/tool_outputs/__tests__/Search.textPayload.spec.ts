import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import Search from '../Search.vue'

// The shape a DEFAULT-format search result has: the tool renders `rg -n` bytes
// and the envelope wraps them as `_raw`. The card read only the JSON shape, so
// this payload used to render "0 files, 0 matches" while the model had the lines.
const textPayload = {
  tool: 'search',
  parameters: { pattern: 'TODO|FIXME', path: '/repo', cwd: '/repo' },
  success: true,
  data: {
    _raw: [
      '/repo/a.zig:127:/// `collect_ignore` half. TODO(port): no Zig consumer.',
      '/repo/a.zig:232:// TODO(port): Python ALSO covered a symlink',
      '/repo/b.ts:12:const FIXME = 1',
    ].join('\n'),
  },
}

describe('Search.vue — the default text payload', () => {
  it('counts the files and matches the tool actually returned', () => {
    const wrapper = mount(Search, { props: { content: textPayload as never } })
    const text = wrapper.text()
    expect(text).toContain('2 files')
    expect(text).toContain('3 matches')
    expect(text).not.toContain('0 files')
  })

  it('lists the matched lines once expanded', () => {
    const wrapper = mount(Search, {
      props: { content: textPayload as never, expanded: true },
    })
    const text = wrapper.text()
    expect(text).toContain('/repo/a.zig')
    expect(text).toContain('Python ALSO covered a symlink')
    expect(text).toContain('127')
  })

  it('opens on the header click and lists every matched line', async () => {
    const wrapper = mount(Search, { props: { content: textPayload as never } })
    expect(wrapper.text()).not.toContain('Python ALSO covered a symlink')

    await wrapper.find('[role="button"]').trigger('click')

    const text = wrapper.text()
    expect(text).toContain('/repo/a.zig')
    expect(text).toContain('127')
    expect(text).toContain('Python ALSO covered a symlink')
    expect(text).toContain('2/2')
  })

  it('names the pattern and path the app hands it, not "unknown"', () => {
    const wrapper = mount(Search, {
      props: {
        content: textPayload as never,
        parameters: '<pattern>TODO|FIXME</pattern><path>/home/ginwa/pabrik</path>',
      },
    })
    const text = wrapper.text()
    expect(text).toContain('TODO|FIXME')
    expect(text).toContain('/home/ginwa/pabrik')
    expect(text).not.toContain('unknown')
  })

  it('shows the tool warning instead of a zero count when nothing matched', () => {
    const wrapper = mount(Search, {
      props: {
        content: {
          tool: 'search',
          success: true,
          data: { _raw: '<warning>no matches for pattern "zzz" in path "/repo"</warning>' },
        } as never,
      },
    })
    expect(wrapper.text()).toContain('no matches for pattern')
    expect(wrapper.text()).not.toContain('0 files')
  })

  it('reads the truncation note into the summary', () => {
    const wrapper = mount(Search, {
      props: {
        content: {
          tool: 'search',
          success: true,
          data: {
            _raw: '/repo/a.ts:1:hit\n[truncated: showing 1 of 40 matches — raise max_results]',
          },
        } as never,
      },
    })
    expect(wrapper.text()).toContain('1 of 40 matches')
  })
})

import { mount } from '@vue/test-utils'
import { beforeAll, describe, expect, it } from 'vitest'
import TextReplace from '../TextReplace.vue'
import DiffView from '../_shared/DiffView.vue'
import ToolParameters from '../_shared/ToolParameters.vue'

beforeAll(() => {
  Object.defineProperty(globalThis, 'localStorage', {
    value: (() => {
      const store = new Map<string, string>()
      return {
        getItem: (k: string) => store.get(k) ?? null,
        setItem: (k: string, v: string) => store.set(k, v),
        removeItem: (k: string) => store.delete(k),
        clear: () => store.clear(),
        get length() {
          return store.size
        },
        key: (i: number) => Array.from(store.keys())[i] ?? null,
      }
    })(),
    writable: true,
    configurable: true,
  })
})

describe('TextReplace.vue — diff fallback + filtered Arguments', () => {
  it('error envelope with null data does not render a diff from attempted parameters', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'line1\nline2',
      new_str: 'line1\nLINE2-EDITED',
    })
    // Error path: ChatView passes the full envelope as content, so
    // normalizeToolContent yields data=null + error message.
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: OldStrNotFound',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: { content: envelope, parameters: params, expanded: true } as never,
    })
    // The attempted edit failed, so it must not be presented as an applied diff.
    expect(wrapper.findComponent(DiffView).exists()).toBe(false)
    expect(wrapper.html()).not.toContain('Before')
    expect(wrapper.html()).not.toContain('After')
    // Arguments still remain available for diagnosing the failed call.
    const args = wrapper.findComponent(ToolParameters)
    expect(args.exists()).toBe(true)
    expect(args.find('pre').text()).toContain('/proj/a.txt')
    expect(args.find('pre').text()).not.toContain('LINE2-EDITED')
    expect(args.find('pre').text()).not.toContain('old_str')
  })

  it('MissingField error does not render a partial diff from the replacement', async () => {
    // The LLM used `old_string` instead of the tool schema's `old_str`.
    // The backend rejects the call before touching the file; rendering the
    // still-present `new_str` would incorrectly look like a pure insertion.
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_string: 'line1\\nline2',
      new_str: 'line1\\nLINE2-EDITED',
    })
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: MissingField',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: { content: envelope, parameters: params, expanded: true } as never,
    })
    expect(wrapper.findComponent(DiffView).exists()).toBe(false)
    expect(wrapper.html()).toContain('MissingField')
    expect(wrapper.html()).not.toContain('Before')
    expect(wrapper.html()).not.toContain('After')
  })

  it('success envelope keeps envelope diff and hides old_str/new_str from Arguments', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'aaa',
      new_str: 'bbb',
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: {
          path: '/proj/a.txt',
          before: 'aaa',
          after: 'bbb',
          unified: '@@',
          lines_changed: 2,
          error: null,
        },
        parameters: params,
        expanded: true,
      } as never,
    })
    expect(wrapper.html()).toContain('Before')
    const args = wrapper.findComponent(ToolParameters)
    expect(args.find('pre').text()).toContain('/proj/a.txt')
    expect(args.find('pre').text()).not.toContain('old_str')
    expect(args.find('pre').text()).not.toContain('new_str')
  })

  it('successful delete (new_str="") still renders its applied diff', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'remove me',
      new_str: '',
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: {
          path: '/proj/a.txt',
          before: 'remove me',
          after: '',
          error: null,
        },
        parameters: params,
        expanded: true,
      } as never,
    })
    expect(wrapper.findComponent(DiffView).exists()).toBe(true)
    expect(wrapper.html()).toContain('Before')
  })

  // Regression: the DB diffview_* columns are NULL (backend only fills them from legacy XML), so
  // ChatView passes explicit null props. Null must fall through to the envelope data — passing it
  // into DiffView crashes splitLines (Cannot read properties of null).
  it('explicit null diffview props fall through to envelope data (no crash)', async () => {
    const params = JSON.stringify({
      path: '/tmp/pabrik_dummy_test.txt',
      old_str: 'test again - second replacement works!',
      new_str: 'again - third replacement works! count: 3',
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: {
          path: '/tmp/pabrik_dummy_test.txt',
          unified: '@@ -1,2 +1,2 @@',
          before: 'test again - second replacement works!',
          after: 'again - third replacement works! count: 3',
          lines_changed: 2,
          error: null,
        },
        parameters: params,
        expanded: true,
        diffviewBefore: null,
        diffviewAfter: null,
      } as never,
    })
    expect(wrapper.html()).toContain('Before')
    expect(wrapper.html()).toContain('After')
  })

  it('null diffview props + error envelope does not diff from parameters', async () => {
    const params = JSON.stringify({
      path: '/proj/a.txt',
      old_str: 'aaa',
      new_str: 'bbb',
    })
    const envelope = JSON.stringify({
      tool: 'text_replace',
      parameters: JSON.parse(params),
      success: false,
      data: null,
      error: 'text_replace failed: OldStrNotFound',
      v: 1,
    })
    const wrapper = mount(TextReplace, {
      props: {
        content: envelope,
        parameters: params,
        expanded: true,
        diffviewBefore: null,
        diffviewAfter: null,
      } as never,
    })
    expect(wrapper.findComponent(DiffView).exists()).toBe(false)
    expect(wrapper.html()).not.toContain('Before')
    expect(wrapper.html()).not.toContain('After')
  })
})

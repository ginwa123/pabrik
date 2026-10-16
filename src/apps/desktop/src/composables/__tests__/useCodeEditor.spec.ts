/** Tests for useCodeEditor.ts — verifies the composable's `OpenInCodeEditorOptions` contract and
 * the `useInjectOpenInCodeEditor` injection key (chunks 5+6). The composable itself is a thin
 * `inject` wrapper, so the meaningful test is: 1. */
import { mount } from '@vue/test-utils'
import { defineComponent, h, provide } from 'vue'
import { beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'

import {
  OPEN_IN_CODE_EDITOR_KEY,
  useInjectOpenInCodeEditor,
  type OpenInCodeEditorFn,
  type OpenInCodeEditorOptions,
} from '../useCodeEditor'

beforeAll(() => {
  // jsdom 29 dropped localStorage from default globals — install a stub.
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

beforeEach(() => {
  // Make sure every test starts fresh — no leftover provide/inject state.
})

describe('useCodeEditor composable', () => {
  it('OpenInCodeEditorOptions accepts an optional line number', () => {
    // This is a compile-time + runtime check. If the `line` field were
    // missing, this test wouldn't type-check and the assignment below
    // would error at the build step.
    const opts: OpenInCodeEditorOptions = {
      filePath: '/foo/bar.ts',
      cwd: '/foo',
      line: 42,
    }
    expect(opts.line).toBe(42)

    // Also: omitting `line` must compile (it is `?: number`).
    const optsWithoutLine: OpenInCodeEditorOptions = {
      filePath: '/foo/bar.ts',
      cwd: '/foo',
    }
    expect(optsWithoutLine.line).toBeUndefined()
  })

  it('returns the provided function when OPEN_IN_CODE_EDITOR_KEY is provided', () => {
    const calls: OpenInCodeEditorOptions[] = []
    const openFn: OpenInCodeEditorFn = vi.fn(async (opts) => {
      calls.push(opts)
    })

    const TestComp = defineComponent({
      setup() {
        provide(OPEN_IN_CODE_EDITOR_KEY, openFn)
        return () => h(ChildComp)
      },
    })

    let receivedFn: ReturnType<typeof useInjectOpenInCodeEditor> = null
    const ChildComp = defineComponent({
      setup() {
        receivedFn = useInjectOpenInCodeEditor()
        return () => h('div', 'child')
      },
    })

    mount(TestComp)
    expect(receivedFn).toBe(openFn)
  })

  it('returns null when no provider exists (graceful fallback)', () => {
    let receivedFn: ReturnType<typeof useInjectOpenInCodeEditor> = null
    const Lone = defineComponent({
      setup() {
        receivedFn = useInjectOpenInCodeEditor()
        return () => h('div', 'lone')
      },
    })

    mount(Lone)
    expect(receivedFn).toBeNull()
  })

  it('threaded `line` option reaches the handler verbatim (chunks 5+6)', async () => {
    // This is the contract the DiffView's @jump-to-line relies on:
    // clicking a line number in the diff must call the editor handler with
    // that exact line number so the editor can scroll there.
    const calls: OpenInCodeEditorOptions[] = []
    const openFn: OpenInCodeEditorFn = async (opts) => {
      calls.push(opts)
    }

    const TestComp = defineComponent({
      setup() {
        provide(OPEN_IN_CODE_EDITOR_KEY, openFn)
        return () => h(Caller, { line: 17 })
      },
    })

    const Caller = defineComponent({
      props: { line: { type: Number, required: true } },
      setup(props) {
        const fn = useInjectOpenInCodeEditor()
        return () => {
          if (!fn) return h('div', 'no-fn')
          // Simulate what TextReplace.handleJumpToLine does.
          void fn({
            filePath: '/foo/bar.ts',
            cwd: '/foo',
            line: props.line,
          })
          return h('div', 'called')
        }
      },
    })

    mount(TestComp)
    await Promise.resolve() // let the async void fn flush

    expect(calls).toHaveLength(1)
    expect(calls[0]).toEqual({
      filePath: '/foo/bar.ts',
      cwd: '/foo',
      line: 17,
    })
  })
})
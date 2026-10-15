/** Behavioural tests for the read-only code viewer (`views/CodeEditor.vue`), rendered from
 * `?view=code-editor`. */
/** Regression context (task_1790594549955_1, "when i click code editor there is no code"): the
 * previous implementation lazy-loaded monaco with a dynamic import marked `@vite-ignore`. */
/** That marker makes Vite keep the BARE specifier in the production bundle
 * (``import(`monaco-editor`)``), which no browser can resolve — `onMounted` rejected and the body
 * stayed empty while the header still rendered. */
/** The old spec only grepped the source for the import shape, so it passed while the shipped bundle
 * was broken. These tests therefore assert the OBSERVABLE viewer: real rows, real line numbers,
 * real syntax tokens — plus a source contract that no browser-unresolvable dependency comes
 * back. */
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import CodeEditor from '../CodeEditor.vue'

const codeEditorPath = resolve(__dirname, '..', 'CodeEditor.vue')
const source = readFileSync(codeEditorPath, 'utf-8')

/**  * Strip comment bodies before the source-contract greps below: this file's own header explains
 * *why* the component no longer uses monaco, so the word appears in prose. Only executable code
 * matters. */
function stripComments(src: string): string {
  return src
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')
}

const code = stripComments(source)

const TS_BODY = [
  '// a comment',
  'export function greet(name: string): string {',
  "  const marker = 'CODE_VIEWER_MARKER'",
  '  return `hello ${name}`',
  '}',
].join('\n')

function mountViewer(props: Record<string, unknown> = {}) {
  return mount(CodeEditor, {
    props: {
      filePath: '/w/sample.ts',
      fileName: 'sample.ts',
      cwd: '/w',
      content: TS_BODY,
      ...props,
    },
  })
}

const rows = (wrapper: ReturnType<typeof mountViewer>) =>
  wrapper.findAll('[data-testid="code-line"]')

describe('CodeEditor.vue — renders the file (not a blank body)', () => {
  it('paints one numbered row per line of the file', () => {
    const wrapper = mountViewer()

    expect(wrapper.attributes('data-testid')).toBe('code-editor')
    const lineRows = rows(wrapper)
    expect(lineRows).toHaveLength(5)
    expect(lineRows.map((r) => r.attributes('data-line'))).toEqual(['1', '2', '3', '4', '5'])
    expect(wrapper.findAll('[data-testid="code-line-number"]').map((c) => c.text())).toEqual([
      '1',
      '2',
      '3',
      '4',
      '5',
    ])
  })

  it('renders the file text verbatim', () => {
    const wrapper = mountViewer()
    const text = wrapper.get('[data-testid="code-editor-body"]').text()

    expect(text).toContain('CODE_VIEWER_MARKER')
    expect(text).toContain('export function greet(name: string): string {')
  })

  it('does not number a phantom line for a trailing newline', () => {
    const wrapper = mountViewer({ content: 'one\ntwo\n' })
    expect(rows(wrapper)).toHaveLength(2)
  })

  it('colors tokens with the shared diff-review palette', () => {
    const wrapper = mountViewer()

    // `export` / `function` / `const` / `return` are TS keywords.
    expect(wrapper.findAll('.tok-keyword').length).toBeGreaterThan(0)
    expect(wrapper.find('.tok-comment').text()).toBe('// a comment')
    expect(wrapper.find('.tok-string').text()).toBe("'CODE_VIEWER_MARKER'")
  })

  it('renders markdown/plaintext without token classes', () => {
    const wrapper = mountViewer({
      filePath: '/w/AGENTS.md',
      fileName: 'AGENTS.md',
      content: '# AGENTS\n\nplain body\n',
    })

    expect(wrapper.get('[data-testid="code-editor-body"]').text()).toContain('plain body')
    expect(wrapper.findAll('.tok-keyword')).toHaveLength(0)
    expect(wrapper.get('[data-testid="code-editor-language"]').text()).toBe('markdown')
  })

  it('colors the Diff view rows, not just the code view', async () => {
    const wrapper = mountViewer({
      diffText: ['@@ -1,2 +1,2 @@', ' const kept = 1', '-const gone = 2', '+const added = 3'].join(
        '\n',
      ),
    })

    // The Code/Diff toggle only appears when a diff is available.
    await wrapper.get('[data-testid="code-diff-toggle"]').trigger('click')

    const diffView = wrapper.get('[data-testid="code-diff-view"]')
    expect(diffView.findAll('.tok-keyword').map((s) => s.text())).toEqual([
      'const',
      'const',
      'const',
    ])
    // The change sign stays glued to the code it marks.
    expect(diffView.text()).toContain('+const added = 3')
    expect(diffView.text()).toContain('-const gone = 2')

    // A hunk header is diff METADATA: tokenizing `@@ -1,2 +1,2 @@` would
    // paint its numbers `.tok-number` over the row's hunk colour, which no
    // other unified surface does. It stays one plain span.
    const hunkRow = diffView.get('.diff-row-hunk')
    expect(hunkRow.text()).toContain('@@ -1,2 +1,2 @@')
    expect(hunkRow.findAll('.tok-number')).toHaveLength(0)
    expect(hunkRow.findAll('.tok-plain')).toHaveLength(1)
  })

  it('marks the requested line (diff review "open at this line")', () => {
    const wrapper = mountViewer({ line: 3 })

    const target = wrapper.findAll('[data-testid="code-line"][data-target="true"]')
    expect(target).toHaveLength(1)
    expect(target[0]!.attributes('data-line')).toBe('3')
    expect(target[0]!.text()).toContain('CODE_VIEWER_MARKER')
  })

  it('shows an explicit empty state for an empty file', () => {
    const wrapper = mountViewer({ content: '' })

    expect(wrapper.find('[data-testid="code-editor-empty"]').exists()).toBe(true)
    expect(rows(wrapper)).toHaveLength(0)
  })

  it('reports the language and line count in the header', () => {
    const wrapper = mountViewer()

    expect(wrapper.get('[data-testid="code-editor-language"]').text()).toBe('typescript')
    expect(wrapper.get('[data-testid="code-editor-line-count"]').text()).toBe('5 lines')
  })

  it('emits close from the header button', async () => {
    const wrapper = mountViewer()
    await wrapper.get('[data-testid="code-editor-close"]').trigger('click')
    expect(wrapper.emitted('close')).toHaveLength(1)
  })
})

describe('CodeEditor.vue — source contract', () => {
  it('does not reference the monaco-editor package at all', () => {
    // The production bundle broke because `import('monaco-editor')` was left as a runtime
    // specifier. The viewer renders with the repo's zero-dependency tokenizer, so the package must
    // not be named here.

    // (Matched as a quoted specifier — the `ui-monospace … Monaco …` font stack is a font name, not
    // a module.)
    expect(code).not.toMatch(/['"`]monaco-editor['"`]/)
  })

  it('does not use the @vite-ignore escape hatch for a bare import', () => {
    // `@vite-ignore` keeps the specifier verbatim in the emitted chunk —
    // that is exactly what shipped ``import(`monaco-editor`)`` to the
    // browser. Nothing in this component may need it.
    expect(code).not.toMatch(/@vite-ignore/)
  })

  it('renders through the shared tokenizer helper', () => {
    expect(code).toMatch(/highlightLine/)
    expect(code).toMatch(/from '@\/helpers\/codeHighlight'/)
  })
})

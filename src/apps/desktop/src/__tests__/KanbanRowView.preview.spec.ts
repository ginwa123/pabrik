/** Renders the real <KanbanRowView> to static HTML for visual review. This is a REVIEW HARNESS, not
 * a test — there are no assertions. */

/** It mounts the actual component with realistic fixtures, serializes the result, and inlines the
 * real compiled Tailwind CSS so the output can be opened in a browser and judged by eye. */

/** Green unit tests prove the row emits the right events; they cannot prove the row is readable,
 * which is a visual property. Run: npx vitest --run src/__tests__/KanbanRowView.preview.spec.ts
 * Out: /tmp/kanban-row-comfortable.html + /tmp/kanban-row-compact.html */
import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'

import KanbanRowView from '../components/kanban/KanbanRowView.vue'
import type { KanbanColumn, Task } from '../stores/workspaces'

const ITEM_ID = 'item_preview'
const HOUR = 3600_000
const now = Date.now()

const columns: KanbanColumn[] = [
  {
    id: 'col_1',
    workspace_item_id: ITEM_ID,
    name: 'todo',
    position: 0,
    created_at: '2026-09-26 12:00:00',
    description: 'planning is method before execute implement feature. you give a human a planning',
  },
  {
    id: 'col_2',
    workspace_item_id: ITEM_ID,
    name: 'merged',
    position: 1,
    created_at: '2026-09-26 12:00:00',
    description:
      'this is MANDATORY !!!! already merged in main branch, if still not merged in main branch, dont put here !!!!!, also only human put the task here !!!!',
  },
]

// One row per state in the wireframe, with a long name and a long branch
// to exercise the truncation paths.
const tasks: Task[] = [
  {
    id: 't1',
    name: 'make the kanban row, more readble',
    kanban_column_id: 'col_1',
    updatedAt: new Date(now - 12 * 60_000),
    needs_human_review: true,
    last_finish_reason: 'stop',
    git_branch: 'worktree/make-the-kanban-row-more-readble-1790442544586',
    tags: ['agentic', 'ui'],
  },
  {
    id: 't2',
    name: 'check why I got error SystemResource ? i already restarted the service and i cannot reproduce the issuess',
    kanban_column_id: 'col_1',
    updatedAt: new Date(now - 3 * 24 * HOUR),
    is_pinned: true,
    last_finish_reason: 'stop',
    git_branch: 'main',
  },
  {
    id: 't3',
    name: 'gitlab support',
    kanban_column_id: 'col_2',
    updatedAt: new Date(now - 1 * HOUR),
    last_finish_reason: 'stop',
    tags: ['backend', 'wip', 'infra', 'extra'],
  },
  {
    id: 't4',
    name: 'trace and fix why I got this error crash',
    kanban_column_id: 'col_2',
    updatedAt: new Date(now - 90_000),
    git_branch: 'worktree/trace-crash-1790442544586',
  },
  {
    id: 't5',
    name: 'ten default is expand, but still can collapsed though for agent and subagent profile',
    kanban_column_id: 'col_2',
    updatedAt: new Date(now - 22 * 24 * HOUR),
  },
]

const SHELL_CSS = `
  body { margin: 0; background: #181616; }
  .shell { display: flex; height: 660px; }
  .side { width: 150px; background: #12120f; border-right: 1px solid #282727;
          padding: 10px 0; font-size: 12px; color: #7a8382; }
  .side div { padding: 5px 12px; }
  .side .on { color: #c5c9c5; background: #282727; }
  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .head { display: flex; align-items: center; gap: 10px; padding: 9px 12px;
          border-bottom: 1px solid #282727; }
  .title { font-size: 13px; font-weight: 600; flex: 1; }
  .pill { padding: 4px 9px; border-radius: 5px; font-size: 12px;
          border: 1px solid #282727; color: #a6a69c; }
  .pill.on { background: #8992a7; color: #181616; font-weight: 600; border-color: #8992a7; }
`

function page(body: string, density: string): string {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>kanban row — ${density}</title>
<style>${readFileSync(cssPath, 'utf-8')}</style>
<style>${SHELL_CSS}</style>
</head><body>
<div class="shell">
  <div class="side"><div class="on">▦ AGENTIC_KANBAN</div><div>📁 design</div><div>📁 kabelweb</div></div>
  <div class="main">
    <div class="head">
      <span class="title">AGENTIC_KANBAN</span>
      <span class="pill">▦ Columns</span><span class="pill on">☰ Rows</span>
      <span class="pill">${density === 'compact' ? '≡ Compact' : '☰ Comfortable'}</span>
      <span class="pill">🔍 search</span><span class="pill">➕ Add task</span>
    </div>
    ${body}
  </div>
</div>
</body></html>`
}

// The compiled bundle carries the exact same custom properties the app
// uses, so the preview is colour-accurate rather than approximate.
let cssPath = ''
try {
  const cssDir = join(process.cwd(), 'dist/assets')
  cssPath = join(
    cssDir,
    readdirSync(cssDir).find((f) => f.endsWith('.css'))!,
  )
} catch {
  cssPath = ''
}

describe('KanbanRowView visual preview generator', () => {
  it('writes a static HTML page per density', () => {
    setActivePinia(createPinia())
    mkdirSync('/tmp/kanban-row-preview', { recursive: true })

    for (const density of ['comfortable', 'compact'] as const) {
      const wrapper = mount(KanbanRowView, {
        props: {
          columns,
          tasks,
          workspaceId: 'ws_preview',
          itemId: ITEM_ID,
          collapsedIds: [],
          runAllBusyByColumn: {},
          density,
        },
      })
      const html = page(wrapper.html(), density)
      const out = `/tmp/kanban-row-preview/kanban-row-${density}.html`
      writeFileSync(out, html)
      console.log(`[preview] wrote ${out} (${html.length} bytes)`)
      wrapper.unmount()

      // The harness is worthless if it writes an empty page — assert the
      // rows and the density actually made it into the output, so a
      // broken mount fails here instead of producing a blank PNG.
      expect(html).toContain(`data-kanban-row-density="${density}"`)
      expect(html).toContain('data-kanban-row="t1"')
      expect(html).toContain('data-task-row')
      expect(existsSync(out)).toBe(true)
      // Comfortable carries the metadata line; compact must not.
      const metaCount = (html.match(/kanban-row-meta/g) ?? []).length
      expect(metaCount === 5).toBe(density === 'comfortable')
    }
  })
})

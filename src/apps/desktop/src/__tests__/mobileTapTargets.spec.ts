import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const css = readFileSync(resolve(SRC, 'style.css'), 'utf8')

function phoneBlock(): string {
  const blocks: string[] = []
  let from = css.indexOf('@media (max-width: 767px)')
  while (from !== -1) {
    let depth = 0
    let i = css.indexOf('{', from)
    const start = i
    for (; i < css.length; i++) {
      if (css[i] === '{') depth++
      else if (css[i] === '}') {
        depth--
        if (depth === 0) break
      }
    }
    blocks.push(css.slice(start, i + 1))
    from = css.indexOf('@media (max-width: 767px)', i)
  }
  return blocks.join('\n')
}

/** CSS is the only place a tap target can regress with every other gate stays green: neither vitest
 * nor vue-tsc sees a width. The browser numbers behind this contract are in PR #1288 (the workspace
 * switcher was an 18px line, New Chat 40px, the section headers 27px, switcher rows 34px). */
describe('phone tap targets in the sidebar', () => {
  const block = phoneBlock()

  it('declares its own row and hit tokens for a phone', () => {
    expect(block).toContain('--sb-row: 44px')
    expect(block).toContain('--sb-hit: 44px')
  })

  it('grows every high-traffic navigation control to 44px', () => {
    const selectors = [
      "[data-testid='workspace-switcher-trigger']",
      "[data-testid='sidebar-new-chat-button']",
      "[data-testid$='-section-header']",
      "[data-testid^='workspace-switcher-option-']",
      "[data-testid^='workspace-switcher-rename-']",
      "[data-testid^='workspace-switcher-delete-']",
      "[data-testid='sidebar-settings-button']",
    ]
    const missing = selectors.filter((s) => !block.includes(s))
    expect(missing).toEqual([])
    expect(block).toContain('min-height: 44px')
  })

  it('lets the board header wrap, so the page cannot be scrolled sideways', () => {
    // The header carried 690px of content in a 390px box; focusing a form field in the task
    // detail then scrolled <main> and dragged that overlay off the left edge.
    expect(block).toContain('.kanban-board-header')
    expect(block).toContain('flex-wrap: wrap')
    expect(block).toContain('.kanban-search')
  })
})

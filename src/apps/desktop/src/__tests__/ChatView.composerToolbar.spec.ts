/** ChatView V1 composer toolbar — static contract (mirrors the DiffCommentBox.spec.ts
 * source-reading pattern; mounting the full ChatView needs the profileCascade harness). */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dir = dirname(fileURLToPath(import.meta.url))
const chatViewSrc = readFileSync(resolve(__dir, '../components/views/ChatView.vue'), 'utf8')

// The toolbar block: from `<template #toolbar>` to its close. All
// toolbar assertions scope to this slice so matches elsewhere in the
// 5k-line file (e.g. message bubbles) can't false-positive.
const toolbarSrc = (() => {
  const start = chatViewSrc.indexOf('<template #toolbar>')
  const end = chatViewSrc.indexOf('</template>', start)
  if (start === -1 || end === -1) throw new Error('toolbar template not found')
  return chatViewSrc.slice(start, end)
})()

describe('ChatView composer toolbar (V1 single-card)', () => {
  it('projects the status row into FileInput’s toolbar slot', () => {
    expect(chatViewSrc).toContain('<template #toolbar>')
    // The old detached row is gone.
    expect(chatViewSrc).not.toContain('<!-- Status bar -->')
    expect(chatViewSrc).not.toMatch(/<div class="flex items-center gap-2 mt-3">/)
  })

  it('keeps every interactive hook (testids, dropdowns, titles)', () => {
    for (const hook of [
      'profile-picker-button',
      'profile-picker-default',
      'profile-picker-active-badge',
      'worktree-status-button',
      'tokens-status',
    ]) {
      expect(toolbarSrc).toContain(`data-testid="${hook}"`)
    }
    expect(toolbarSrc).toContain('<WorktreeMenu')
    expect(toolbarSrc).toContain('profileChipTooltip')
    expect(toolbarSrc).toContain('Compact conversation history')
  })

  it('truncates the branch label and compacts the token readout', () => {
    expect(toolbarSrc).toContain('composer-branch-label')
    expect(toolbarSrc).toContain('formatCompactTokens(maxTotalTokens)')
    expect(toolbarSrc).toContain('formatCompactTokens(maxCapacityTotalTokens)')
    // Exact numbers survive in the tooltip.
    expect(toolbarSrc).toContain('maxTotalTokens.toLocaleString()')
  })

  it('uses no emoji icons in the toolbar', () => {
    for (const emoji of ['🗜️', '🤖', '🌿', '🧠']) {
      expect(toolbarSrc).not.toContain(emoji)
    }
  })
})

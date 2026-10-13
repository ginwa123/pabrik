/**
 * The banned-code plugin. Registered in `eslint.config.ts` as `local/…`.
 *
 * Keep the ban list and the enforcement in one place: if a rule exists here,
 * some rule or ratchet enforces it, and if a pattern is banned, it is
 * implemented in this directory.
 */
import type { Rule } from 'eslint'
import { noDerivedStateWatch } from './bannedCode'
import { noSilentFallbackCatch } from './noSilentFallbackCatch'
import { noTryCatch } from './noTryCatch'
import { noWatch } from './noWatch'
import { noWatchArraySource } from './noWatchArraySource'
import { noWatchEffect } from './noWatchEffect'
import { noWatchFeedbackLoop } from './noWatchFeedbackLoop'

const rules: Record<string, Rule.RuleModule> = {
  'no-derived-state-watch': noDerivedStateWatch,
  'no-silent-fallback-catch': noSilentFallbackCatch,
  'no-try-catch': noTryCatch,
  'no-watch': noWatch,
  'no-watch-array-source': noWatchArraySource,
  'no-watch-effect': noWatchEffect,
  'no-watch-feedback-loop': noWatchFeedbackLoop,
}

const plugin = { rules }

export default plugin

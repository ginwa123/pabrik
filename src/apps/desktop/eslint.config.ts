import { globalIgnores } from 'eslint/config'
import { defineConfigWithVueTs, vueTsConfigs } from '@vue/eslint-config-typescript'
import pluginVue from 'eslint-plugin-vue'
import pluginVitest from '@vitest/eslint-plugin'
import pluginOxlint from 'eslint-plugin-oxlint'
import skipFormatting from 'eslint-config-prettier/flat'
import localBannedCode from './eslint-rules/index'

// To allow more languages other than `ts` in `.vue` files, uncomment the following lines:
// import { configureVueProject } from '@vue/eslint-config-typescript'
// configureVueProject({ scriptLangs: ['ts', 'tsx'] })
// More info at https://github.com/vuejs/eslint-config-typescript/#advanced-setup

export default defineConfigWithVueTs(
  {
    name: 'app/files-to-lint',
    files: ['**/*.{vue,ts,mts,tsx}'],
  },

  globalIgnores(['**/dist/**', '**/dist-ssr/**', '**/coverage/**']),

  ...pluginVue.configs['flat/essential'],
  vueTsConfigs.recommended,

  {
    ...pluginVitest.configs.recommended,
    files: ['src/**/__tests__/*'],
  },

  ...pluginOxlint.buildFromOxlintConfigFile('.oxlintrc.json'),

  // The Vue/TS banned-code rules — the local analogue of React's
  // "you might not need an effect" doctrine, plus the swallowed-error class
  // that PR #719 shipped. See `src/apps/desktop/eslint-rules/bannedCode.ts`.
  //
  // Everything here is severity `error`, because ESLint's `--suppress-rule`
  // only records ERROR-level violations — a `warn` baseline is silently
  // written as an empty `{}` and the ratchet never engages. So the tiering is
  // done by SUPPRESSION, not by severity:
  //
  //   no baselines needed  — zero occurrences; new code fails immediately.
  //   baselined in          — pre-existing debt, pinned by the counts in
  //   eslint-suppressions.json, so the count can only fall. Fix a site and
  //   the baseline shrinks; add one and CI goes red.
  //
  // Regenerate after intentionally fixing debt:
  //   pnpm run lint:banned-baseline
  {
    name: 'app/banned-code',
    files: ['src/**/*.{vue,ts}'],
    plugins: { local: localBannedCode },
    rules: {
      // A comment block may span at most three lines — the Vue/TS half of
      // CODING_STANDARDS.md §4, whose Zig half is `zginlint/max-comment-lines`.
      // Same ceiling, same semantics: a blank line or a code line ends a
      // block, a trailing comment never starts one, and a `/* … */` counts
      // by the lines it spans. HTML comments in `<template>` and CSS
      // comments in `<style>` are out of scope — see the rule file for why
      // each is a documented gap rather than a silent one.
      //
      // 3,822 pre-existing blocks across 733 files, so this rides the same
      // per-file ratchet as the bans below: regenerate with
      // `pnpm run lint:banned-baseline` only after fixing debt, never to
      // silence a new violation. `docs/comment-length-policy.md` is the
      // working companion.
      'local/max-comment-lines': 'error',
      // A comment must attach to the code it explains. The ceiling above is
      // trivially satisfiable by cutting one long comment into several
      // three-line blocks separated by blank lines, which keeps every word on
      // screen and defeats the point — so that shape is banned too. Exactly
      // one blank line between a comment run and the code below it is the
      // finding; two or more is a section break and stays legal.
      'local/no-floating-comments': 'error',
      // Zero occurrences today. `watchEffect` tracks its dependencies
      // implicitly, so a later refactor can silently change when it re-runs —
      // it is the Vue spelling of the useEffect anti-pattern.
      'local/no-watch-effect': 'error',
      // Zero occurrences after the three rewrites below. `watch([a, b], fn)`
      // re-runs when ANY entry changes without saying which one did — the
      // Vue spelling of `useEffect(fn, [a, b])`. Split into one watch per
      // source sharing a handler.
      'local/no-watch-array-source': 'error',
      // Blanket ban: ALL `watch()` calls are prohibited, including the
      // single-source side-effect form. Pre-existing sites are pinned as
      // baseline debt in `eslint-suppressions.json` (regenerate with
      // `pnpm run lint:banned-baseline` only after fixing debt, never to
      // silence a new violation). New watchers fail immediately. Note
      // there is deliberately no sanctioned alternative for external
      // signals (router, SSE, browser chrome) — those cases go to review.
      'local/no-watch': 'error',
      // A watcher that writes back into the value it watches. Vue re-runs a
      // watcher when a dependency it READS changes, so a self-write schedules
      // another run — the loop only ends when the write is accidentally
      // idempotent. Distinct from `no-derived-state-watch`, which allows a
      // callback containing calls; the feedback loop hides in exactly those
      // "legitimate side effect" bodies.
      'local/no-watch-feedback-loop': 'error',
      // 26 baselined sites.
      'local/no-derived-state-watch': 'error',
      // 87 baselined sites.
      'local/no-silent-fallback-catch': 'error',
      // 537 baselined sites (521 production + 13 in specs + 3 in a second
      // <script> block) across 132 files. AGENTS.md has banned try/catch
      // since PR #719; this is what makes it hold. `try { … } finally { … }`
      // with no handler stays legal — see `eslint-rules/noTryCatch.ts` for
      // the full scope decision, including why `promise.catch(fn)` is
      // deliberately NOT banned here.
      'local/no-try-catch': 'error',
      // `@ts-ignore` silences a whole file region with no obligation to
      // explain, and `@ts-nocheck` silences the entire file — both are at
      // zero occurrences here, so both are free to forbid outright.
      //
      // `@ts-expect-error` is allowed WITH a `-- reason`: it documents the
      // suppression and, unlike `@ts-ignore`, it fails the build if the error
      // it covers is ever fixed. The existing uses are deliberate
      // negative-type tests — `sseIsInputOutput.spec.ts` assigns `'1'` to a
      // boolean field precisely to assert the compiler rejects it.
      '@typescript-eslint/ban-ts-comment': [
        'error',
        {
          'ts-ignore': true,
          'ts-nocheck': true,
          'ts-check': false,
          'ts-expect-error': 'allow-with-description',
          minimumDescriptionLength: 8,
        },
      ],
      // Already at zero — every one of the 631 `as any` in this repo carries
      // an inline `// eslint-disable-next-line … -- <reason>`, so switching
      // the rule on costs nothing and makes that discipline enforceable for
      // new code. `any` erases the error channel this repo is trying to widen.
      '@typescript-eslint/no-explicit-any': 'error',
    },
  },

  skipFormatting,
)

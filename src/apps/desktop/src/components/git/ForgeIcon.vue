<script setup lang="ts">
/**
 * The forge's own mark — GitHub or GitLab — as inline SVG.
 *
 * The panel used to say 🔀 for both, which is the exact bug
 * `helpers/forgeWording.ts` exists to prevent in prose: a GitLab user's
 * merge request rendered with the same glyph as a GitHub user's pull
 * request, so nothing on screen said which forge they were looking at.
 * A brand mark answers that without a word, and it is legible at 12px
 * where a label would truncate.
 *
 * Both paths are the Simple Icons 24x24 marks (CC0-1.0). They are filled
 * with `currentColor` rather than their brand hex on purpose: the app is
 * dark-only and muted (--semantic-text #c5c9c5, --color-violet #8992a7),
 * and GitLab's #FC6D26 orange beside the kanagawa palette reads as an
 * error. A mark that inherits the surrounding text colour stays legible
 * in every context and never fights the palette.
 *
 * Unknown providers fall back to GitHub — the same default
 * `forgeWording()` uses, because `pr_provider` is empty on every session
 * created before GitLab support existed.
 */
import { computed } from 'vue'

const GITHUB_PATH =
  'M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12'

const GITLAB_PATH =
  'm23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z'

const props = withDefaults(
  defineProps<{
    /** `gitlab` or anything else. Unknown falls back to GitHub. */
    provider?: string | null
    /** Tailwind sizing class. Defaults to 16px, the inline-glyph step. */
    sizeClass?: string
    /**      * Accessible name. Leave unset when a visible label already names the forge — the icon is then
     * decorative and must be aria-hidden, not announced as "GitHub" after "GitHub". */
    title?: string | null
  }>(),
  { provider: null, sizeClass: 'w-4 h-4', title: null },
)

const isGitlab = computed(() => props.provider === 'gitlab')
const markPath = computed(() => (isGitlab.value ? GITLAB_PATH : GITHUB_PATH))
const label = computed(() => (isGitlab.value ? 'GitLab' : 'GitHub'))
</script>

<template>
  <svg
    :class="sizeClass"
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
    :role="title ? 'img' : undefined"
    :aria-hidden="title ? undefined : 'true'"
    focusable="false"
    :data-forge="isGitlab ? 'gitlab' : 'github'"
  >
    <title v-if="title">{{ title ?? label }}</title>
    <path :d="markPath" />
  </svg>
</template>

export const GIT_PROBE_FAILURE_LIMIT = 3
export const GIT_PROBE_COOLDOWN_MS = 5 * 60_000

const MAX_TRACKED_CWDS = 8

type Probe =
  | { readonly kind: 'repo' }
  | { readonly kind: 'no-repo' }
  | { readonly kind: 'failing'; readonly count: number; readonly at: number }

const probes = new Map<string, Probe>()

function track(cwd: string, probe: Probe): void {
  probes.delete(cwd)
  probes.set(cwd, probe)
  while (probes.size > MAX_TRACKED_CWDS) {
    const oldest = probes.keys().next()
    if (oldest.done) break
    probes.delete(oldest.value)
  }
}

export function mayProbeGit(cwd: string, now: number = Date.now()): boolean {
  const probe = cwd ? probes.get(cwd) : undefined
  if (!probe) return true
  switch (probe.kind) {
    case 'repo':
      return true
    case 'no-repo':
      return false
    case 'failing':
      return probe.count < GIT_PROBE_FAILURE_LIMIT || now - probe.at >= GIT_PROBE_COOLDOWN_MS
  }
}

export function gitProbeAnswer(cwd: string): 'repo' | 'no-repo' | null {
  const probe = cwd ? probes.get(cwd) : undefined
  if (!probe || probe.kind === 'failing') return null
  return probe.kind
}

export function recordGitAnswer(cwd: string, isRepo: boolean): void {
  if (!cwd) return
  track(cwd, { kind: isRepo ? 'repo' : 'no-repo' })
}

export function recordGitFailure(cwd: string, now: number = Date.now()): void {
  if (!cwd) return
  const previous = probes.get(cwd)
  const count = (previous?.kind === 'failing' ? previous.count : 0) + 1
  track(cwd, { kind: 'failing', count, at: now })
}

export function forgetGitProbe(cwd: string): void {
  if (!cwd) return
  probes.delete(cwd)
}

export function clearGitProbeGate(): void {
  probes.clear()
}

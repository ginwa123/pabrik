/** The outcome wording for the board's agent actions: the same messages the component used to spell
 * out inline, in one place, so the "started / network error / unexpected" ladder cannot drift
 * between the dialog button and the card's context menu. */
export interface AgentStartResult {
  success?: boolean
  status?: string
}

/** `null` = the agent actually started. Anything else is the message to show the user. */
export const startAgentFailure = (result: AgentStartResult | undefined): string | null => {
  if (result && result.success && result.status === 'triggered') return null
  if (result && result.success === false) return "Agent didn't start — server reported failure."
  if (result === undefined) return "Agent didn't start — network error."
  return `Agent didn't start — unexpected response.`
}

export interface ColumnBulkResult {
  success?: boolean
  started?: unknown[]
  stopped?: unknown[]
  skipped?: unknown[]
  failed?: unknown[]
}

/** The one-line banner after a bulk column action. */
export const columnBulkSummary = (
  result: ColumnBulkResult | undefined,
  action: 'run' | 'stop',
): string => {
  if (result?.success === false) {
    return action === 'run'
      ? 'Failed to run all agents in column.'
      : 'Failed to stop all agents in column.'
  }
  const done = (action === 'run' ? result?.started : result?.stopped) ?? []
  const skipped = result?.skipped ?? []
  const failed = result?.failed ?? []
  return action === 'run'
    ? `Started ${done.length}, skipped ${skipped.length} (already running), failed ${failed.length}.`
    : `Stopped ${done.length}, skipped ${skipped.length} (not running), failed ${failed.length}.`
}

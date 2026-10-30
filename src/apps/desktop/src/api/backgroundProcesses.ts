import { apiFetch } from './client'

// ─── Session background processes (bg-completion) ──────────────────────────── Backend:
// background_processes_list.zig + background_process_log_get.zig (commit b69111f7). `running` is
// live per row (OS truth, not the status column).
export interface BackgroundProcess {
  pid: number
  command: string
  log_path: string
  started_at: number
  status: string
  running: boolean
}

export interface BackgroundProcessListResponse {
  processes: BackgroundProcess[]
  count: number
}

export interface BackgroundProcessLogResponse {
  pid: number
  log_path: string
  total_bytes: number
  truncated: boolean
  content: string
}

/**  * List all background processes (`command background=true` rows) for a session, ordered by
 * started_at ASC. GET /api/llm/session/:sid/background_processes */
export async function getBackgroundProcesses(
  sessionId: string,
): Promise<BackgroundProcessListResponse> {
  return await apiFetch<BackgroundProcessListResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes`,
    { silent: true },
  )
}

/**  * Read the TAIL of one background process's log file. GET
 * /api/llm/session/:sid/background_processes/:pid/log?max_bytes=20480 `maxBytes` defaults to 20480,
 * clamped server-side to [1, 1048576]. */
export async function getBackgroundProcessLog(
  sessionId: string,
  pid: number,
  maxBytes = 20480,
): Promise<BackgroundProcessLogResponse> {
  const params = new URLSearchParams({ max_bytes: String(maxBytes) })
  return await apiFetch<BackgroundProcessLogResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes/${pid}/log?${params}`,
    { silent: true },
  )
}

import { apiFetch } from './client'

// ─── Session background processes (bg-completion) ────────────────────────────
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

/** List all background processes (`command background=true` rows) for a session, ordered by started_at ASC. */
export async function getBackgroundProcesses(
  sessionId: string,
): Promise<BackgroundProcessListResponse> {
  return await apiFetch<BackgroundProcessListResponse>(
    `/llm/session/${encodeURIComponent(sessionId)}/background_processes`,
    { silent: true },
  )
}

/** Read the TAIL of one background process's log file. */
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

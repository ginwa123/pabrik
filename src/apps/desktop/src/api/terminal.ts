import { apiFetch } from './client'

// ─── Right-sidebar terminal (PTY over REST + poll) ───────────────────────────
export interface TerminalSession {
  id: string
  pid: number
  /** Which console the session actually got: `posix-pty`, `conpty`, `pipe` (the degraded Windows fallback, no VT input) or `guest-pty`. */
  backend: string
}

export interface TerminalOutput {
  data: string
  cursor: number
  exited: boolean
  exit_code: number | null
}

/** Spawn a shell on a fresh PTY. */
export async function createTerminalSession(
  workspaceId: string,
  cwd: string,
  opts: { shell?: string; cols?: number; rows?: number } = {},
): Promise<TerminalSession> {
  return await apiFetch<TerminalSession>(`/terminal/sessions`, {
    method: 'POST',
    // NOTE: apiFetch stringifies `body` itself — pass the object, NOT JSON.stringify (double-encoding yields a JSON string the server rejects with 400; caught live …
    body: { workspace_id: workspaceId, cwd, ...opts },
    silent: true,
  })
}

/** Write keystrokes to the PTY. */
export async function sendTerminalInput(
  id: string,
  data: string,
): Promise<{ ok: boolean; bytes: number }> {
  return await apiFetch<{ ok: boolean; bytes: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/input`,
    { method: 'POST', body: { data }, silent: true },
  )
}

/** Poll output since `cursor`. */
export async function getTerminalOutput(id: string, cursor = 0): Promise<TerminalOutput> {
  const params = new URLSearchParams({ cursor: String(cursor) })
  return await apiFetch<TerminalOutput>(
    `/terminal/sessions/${encodeURIComponent(id)}/output?${params}`,
    { silent: true },
  )
}

/** Resize the PTY window. */
export async function resizeTerminal(
  id: string,
  cols: number,
  rows: number,
): Promise<{ ok: boolean; cols: number; rows: number }> {
  return await apiFetch<{ ok: boolean; cols: number; rows: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/resize`,
    { method: 'POST', body: { cols, rows }, silent: true },
  )
}

/** Kill the shell and drop the session. */
export async function deleteTerminalSession(id: string): Promise<{ ok: boolean }> {
  return await apiFetch<{ ok: boolean }>(`/terminal/sessions/${encodeURIComponent(id)}`, {
    method: 'DELETE',
    silent: true,
  })
}

/** One live terminal session, as the list endpoint reports it. */
export interface TerminalSessionSummary {
  id: string
  /** The workspace the shell belongs to. Empty when the create named none. */
  workspace_id: string
  /** Where the shell started. */
  cwd: string
  cols: number
  rows: number
  exited: boolean
  /** `posix-pty`, `conpty`, `pipe` or `guest-pty`. */
  backend: string
}

/** The live terminal sessions the caller may drive, for the window-level footer's launcher. */
export async function listTerminalSessions(): Promise<TerminalSessionSummary[]> {
  const data = await apiFetch<{ sessions?: TerminalSessionSummary[] }>(`/terminal/sessions`, {
    method: 'GET',
    silent: true,
  })
  return data.sessions ?? []
}

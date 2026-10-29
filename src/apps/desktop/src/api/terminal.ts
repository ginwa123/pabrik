import { apiFetch } from './core'

// ─── Right-sidebar terminal (PTY over REST + poll) ─────────────────────────── Backend:
// terminal_create/input/output/resize/delete.zig (in-memory PTY registry, no migration).
export interface TerminalSession {
  id: string
  pid: number
  /** Which console the session actually got: `posix-pty`, `conpty`, `pipe`
   * (the degraded Windows fallback, no VT input) or `guest-pty`. */
  backend: string
}

export interface TerminalOutput {
  data: string
  cursor: number
  exited: boolean
  exit_code: number | null
}

/** Spawn a shell on a fresh PTY.
 * POST /api/terminal/sessions { workspace_id, cwd, shell?, cols?, rows? } -> 201 { id, pid }
 * `workspaceId` names whose VM hosts it; `--saas` refuses without one. */
export async function createTerminalSession(
  workspaceId: string,
  cwd: string,
  opts: { shell?: string; cols?: number; rows?: number } = {},
): Promise<TerminalSession> {
  return await apiFetch<TerminalSession>(`/terminal/sessions`, {
    method: 'POST',
    // NOTE: apiFetch stringifies `body` itself — pass the object, NOT
    // JSON.stringify (double-encoding yields a JSON string the server
    // rejects with 400; caught live 2026-09-16 via DevTools payload).
    body: { workspace_id: workspaceId, cwd, ...opts },
    silent: true,
  })
}

/** Write keystrokes to the PTY.
 * POST /api/terminal/sessions/:id/input { data } -> 200 { ok, bytes } */
export async function sendTerminalInput(
  id: string,
  data: string,
): Promise<{ ok: boolean; bytes: number }> {
  return await apiFetch<{ ok: boolean; bytes: number }>(
    `/terminal/sessions/${encodeURIComponent(id)}/input`,
    { method: 'POST', body: { data }, silent: true },
  )
}

/**  * Poll output since `cursor`. GET /api/terminal/sessions/:id/output?cursor=N -> 200 { data, cursor,
 * exited, exit_code } */
export async function getTerminalOutput(id: string, cursor = 0): Promise<TerminalOutput> {
  const params = new URLSearchParams({ cursor: String(cursor) })
  return await apiFetch<TerminalOutput>(
    `/terminal/sessions/${encodeURIComponent(id)}/output?${params}`,
    { silent: true },
  )
}

/** Resize the PTY window.
 * POST /api/terminal/sessions/:id/resize { cols, rows } -> 200 { ok, cols, rows } */
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

/** Kill the shell and drop the session.
 * DELETE /api/terminal/sessions/:id -> 200 { ok } */
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
  /** Where the shell started. Host path in local mode, workspace-relative
   * under `--saas`. */
  cwd: string
  cols: number
  rows: number
  exited: boolean
  /** `posix-pty`, `conpty`, `pipe` or `guest-pty`. */
  backend: string
}

/** The live terminal sessions the caller may drive, for the window-level
 * footer's launcher. GET /api/terminal/sessions -> 200 { sessions: [...] }
 * Owner-scoped by the server: a workspace with no shell has no row. */
export async function listTerminalSessions(): Promise<TerminalSessionSummary[]> {
  const data = await apiFetch<{ sessions?: TerminalSessionSummary[] }>(`/terminal/sessions`, {
    method: 'GET',
    silent: true,
  })
  return data.sessions ?? []
}

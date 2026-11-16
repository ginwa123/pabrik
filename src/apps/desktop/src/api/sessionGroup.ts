import { apiFetch } from './client'

export type GroupRole = 'lead' | 'worker'

export interface GroupMember {
  name: string
  role: GroupRole
}

export interface SessionGroup {
  session_id: string
  group: boolean
  lead: string
  members: GroupMember[]
}

/** The roster of a multi-agent chat. */
export async function getSessionGroup(sessionId: string): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(`/llm/session/${encodeURIComponent(sessionId)}/group`, {
    silent: true,
  })
}

/** Add an agent to the chat, or move one that is already there. */
export async function addSessionGroupMember(
  sessionId: string,
  agent: string,
  role: GroupRole = 'worker',
): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(
    `/llm/session/${encodeURIComponent(sessionId)}/group/members`,
    { method: 'POST', body: { agent, role } },
  )
}

/** Take an agent out. */
export async function removeSessionGroupMember(
  sessionId: string,
  agent: string,
): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(
    `/llm/session/${encodeURIComponent(sessionId)}/group/members/${encodeURIComponent(agent)}`,
    { method: 'DELETE' },
  )
}

/** Hand the room to a member. */
export async function setSessionGroupLead(
  sessionId: string,
  agent: string,
): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(`/llm/session/${encodeURIComponent(sessionId)}/group/lead`, {
    method: 'POST',
    body: { agent },
  })
}

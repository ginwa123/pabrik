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

/** The roster of a multi-agent chat. `group` is false until an agent joins.
 * GET /api/llm/session/:sid/group */
export async function getSessionGroup(sessionId: string): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(`/llm/session/${encodeURIComponent(sessionId)}/group`, {
    silent: true,
  })
}

/** Add an agent to the chat, or move one that is already there. The first
 * member to join leads the room.
 * POST /api/llm/session/:sid/group/members */
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

/** Take an agent out. The last member leaving stops the chat being a group.
 * DELETE /api/llm/session/:sid/group/members/:agent */
export async function removeSessionGroupMember(
  sessionId: string,
  agent: string,
): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(
    `/llm/session/${encodeURIComponent(sessionId)}/group/members/${encodeURIComponent(agent)}`,
    { method: 'DELETE' },
  )
}

/** Hand the room to a member. Only a member can lead it.
 * POST /api/llm/session/:sid/group/lead */
export async function setSessionGroupLead(
  sessionId: string,
  agent: string,
): Promise<SessionGroup> {
  return await apiFetch<SessionGroup>(`/llm/session/${encodeURIComponent(sessionId)}/group/lead`, {
    method: 'POST',
    body: { agent },
  })
}

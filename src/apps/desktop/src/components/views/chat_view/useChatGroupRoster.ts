import { computed, ref, type Ref } from 'vue'
import * as api from '../../../api'

export interface ChatGroupRosterDeps {
  sessionId: Ref<string>
}

const failure = (err: unknown): string =>
  err instanceof Error ? err.message : String(err ?? 'request failed')

export function useChatGroupRoster(deps: ChatGroupRosterDeps) {
  const roster = ref<api.SessionGroup | null>(null)
  const isBusy = ref(false)
  const error = ref<string | null>(null)

  const members = computed<api.GroupMember[]>(() => roster.value?.members ?? [])
  const lead = computed<string>(() => roster.value?.lead ?? '')
  const isGroup = computed<boolean>(() => roster.value?.group === true)
  const memberNames = computed<string[]>(() => members.value.map((m) => m.name))

  const isMember = (name: string): boolean => memberNames.value.includes(name)

  const apply = (next: api.SessionGroup): void => {
    roster.value = next
    error.value = null
  }

  const run = async (request: () => Promise<api.SessionGroup>): Promise<void> => {
    if (isBusy.value) return
    isBusy.value = true
    const result = await request().then(
      (next) => next,
      (err: unknown) => err,
    )
    isBusy.value = false
    if (result instanceof Error) {
      error.value = failure(result)
      return
    }
    apply(result as api.SessionGroup)
  }

  const load = async (): Promise<void> => {
    const sid = deps.sessionId.value
    if (!sid) {
      roster.value = null
      return
    }
    const result = await api.getSessionGroup(sid).then(
      (next) => next,
      (err: unknown) => err,
    )
    if (result instanceof Error) {
      error.value = failure(result)
      return
    }
    apply(result as api.SessionGroup)
  }

  const add = (agent: string): Promise<void> => {
    const sid = deps.sessionId.value
    if (!sid || !agent) return Promise.resolve()
    return run(() => api.addSessionGroupMember(sid, agent))
  }

  const remove = (agent: string): Promise<void> => {
    const sid = deps.sessionId.value
    if (!sid || !agent) return Promise.resolve()
    return run(() => api.removeSessionGroupMember(sid, agent))
  }

  const makeLead = (agent: string): Promise<void> => {
    const sid = deps.sessionId.value
    if (!sid || !agent) return Promise.resolve()
    return run(() => api.setSessionGroupLead(sid, agent))
  }

  return {
    roster,
    members,
    lead,
    isGroup,
    memberNames,
    isMember,
    isBusy,
    error,
    load,
    add,
    remove,
    makeLead,
  }
}

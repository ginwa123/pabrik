/** The skills the create-task dialog opens with: the set the user picked the
 * last time they created a task on the same board, scoped per user + board so
 * one board's picks never leak into another's. */
import { userScopedKey } from './userScope'

const KEY_PREFIX = 'pabrik-kanban-skill-defaults:v1'
const NAME_SEPARATOR = '||'

export interface SkillDefaultsStorage {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
}

export function skillDefaultsKey(workspaceId: string, itemId: string): string {
  return userScopedKey(`${KEY_PREFIX}:${workspaceId}:${itemId}`)
}

export function browserSkillDefaultsStorage(): SkillDefaultsStorage | null {
  if (typeof localStorage === 'undefined') return null
  return localStorage
}

export function readSkillDefaults(storage: SkillDefaultsStorage | null, key: string): string[] {
  if (storage === null) return []
  const raw = storage.getItem(key)
  if (raw === null || raw === '') return []
  return uniqueNames(raw.split(NAME_SEPARATOR))
}

export function writeSkillDefaults(
  storage: SkillDefaultsStorage | null,
  key: string,
  names: string[],
): void {
  if (storage === null) return
  storage.setItem(key, uniqueNames(names).join(NAME_SEPARATOR))
}

export function resolveDefaultSkills(saved: string[], availableNames: string[]): string[] {
  const available = new Set(availableNames)
  return uniqueNames(saved).filter((name) => available.has(name))
}

function uniqueNames(raw: string[]): string[] {
  const out: string[] = []
  for (const entry of raw) {
    const name = entry.trim()
    if (name === '' || out.includes(name)) continue
    out.push(name)
  }
  return out
}

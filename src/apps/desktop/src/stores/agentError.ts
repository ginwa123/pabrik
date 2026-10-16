/** `useAgentErrorStore` — Pinia store backing the persistent per-session "agent error" card slot. */
import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface AgentErrorEntry {
  id: string
  content: string
}

export const useAgentErrorStore = defineStore('agentError', () => {
  // session_id → latest error entry. null = cleared/no error yet.
  const bySession = ref<Record<string, AgentErrorEntry | null>>({})

  function setError(sessionId: string, content: string, id?: string): void {
    const entry: AgentErrorEntry = {
      id: id ?? `agent-error-${Date.now()}`,
      content,
    }
    // Spread-then-assign (NEVER mutate in place) so Vue 3's reactive
    // proxy treats this as a new object reference and consumers
    // (ChatView's `store.bySession[sessionId]` watcher) re-render.
    bySession.value = { ...bySession.value, [sessionId]: entry }
  }

  function clearForSession(sessionId: string): void {
    // Idempotent: only spread when the key actually exists, so we don't
    // churn the reactive proxy for sessions we've never errored on.
    if (!(sessionId in bySession.value)) return
    const next = { ...bySession.value }
    delete next[sessionId]
    bySession.value = next
  }

  function errorFor(sessionId: string): AgentErrorEntry | null {
    return bySession.value[sessionId] ?? null
  }

  return {
    bySession,
    setError,
    clearForSession,
    errorFor,
  }
})

<script setup lang="ts">
import EmptyState from './EmptyState.vue'
import SettingsSkeleton from './SettingsSkeleton.vue'
import type { McpServer } from '../../api'

defineProps<{ modelValue: McpServer[]; loading?: boolean }>()
const emit = defineEmits<{
  edit: [server: McpServer]
  delete: [name: string]
  toggle: [name: string]
  add: []
}>()

/** Mask a value to first 3 + last 3 chars, with the middle replaced
 * by asterisks. For very short values the whole thing is shown as
 * asterisks (no first/last reveal that would expose it). */
function maskValue(v: string): string {
  if (v.length <= 8) return '*'.repeat(v.length)
  const head = v.slice(0, 3)
  const tail = v.slice(-3)
  const middle = '*'.repeat(v.length - 6)
  return head + middle + tail
}
</script>

<template>
  <div class="space-y-4">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted);">
      External tool providers the agent can call. Each entry has a unique name, a URL,
      and optional HTTP headers (e.g. <code style="font-family: var(--font-mono);">CONTEXT7_API_KEY</code>).
    </p>

    <div class="flex justify-end">
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add server</button>
    </div>

    <SettingsSkeleton v-if="loading" test-id="mcp-loading-skeleton" />

    <EmptyState
      v-else-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="◇"
      title="No MCP servers yet"
      description="Add an MCP server to give the agent access to external tools (e.g. context7 for documentation, github for code search)."
      cta-label="+ Add server"
      :cta-action="() => emit('add')"
    />

    <ul v-else class="space-y-2" data-testid="mcp-list">
      <li
        v-for="server in modelValue"
        :key="server.name"
        class="px-4 py-3 rounded-md"
        :class="{ 'opacity-60': server.enabled === false }"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div class="text-body font-medium flex items-center gap-2" style="color: var(--semantic-text);">
              <span>{{ server.name }}</span>
              <span
                class="text-micro px-1.5 h-4 inline-flex items-center rounded font-medium uppercase tracking-wide"
                :style="{
                  color: (server.transport ?? 'http') === 'stdio' ? 'var(--color-violet)' : 'var(--semantic-text-dim)',
                  borderColor: (server.transport ?? 'http') === 'stdio' ? 'var(--color-violet)' : 'var(--color-border)',
                  border: '1px solid',
                }"
              >{{ server.transport ?? 'http' }}</span>
              <span
                v-if="server.enabled === false"
                data-testid="disabled-pill"
                class="text-micro px-1.5 h-4 inline-flex items-center rounded font-medium uppercase tracking-wide"
                style="color: var(--color-red); border: 1px solid var(--color-red);"
              >Disabled</span>
            </div>
            <div
              v-if="(server.transport ?? 'http') === 'stdio'"
              class="text-dense font-mono mt-0.5 truncate"
              style="color: var(--semantic-text-dim);"
            >$ {{ server.command }}{{ (server.args ?? []).length ? ' ' + (server.args ?? []).join(' ') : '' }}</div>
            <div
              v-else
              class="text-dense font-mono mt-0.5 truncate"
              style="color: var(--semantic-text-dim);"
            >{{ server.url }}</div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="toggle-btn"
              @click="emit('toggle', server.name)"
              :aria-pressed="server.enabled ?? true"
              title="Enable/Disable server"
              :aria-label="(server.enabled ?? true) ? 'Disable server' : 'Enable server'"
              class="w-9 h-5 rounded-full border transition-colors duration-150 flex items-center px-0.5"
              :style="(server.enabled ?? true)
                ? { borderColor: 'var(--color-violet)', backgroundColor: 'var(--color-violet)', justifyContent: 'flex-end' }
                : { borderColor: 'var(--color-border)', backgroundColor: 'transparent', justifyContent: 'flex-start' }"
            >
              <span
                class="w-3.5 h-3.5 rounded-full"
                :style="(server.enabled ?? true)
                  ? { backgroundColor: 'var(--semantic-bg)' }
                  : { backgroundColor: 'var(--semantic-text-dim)' }"
              ></span>
            </button>
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', server)"
              class="px-2.5 h-7 rounded-md text-dense border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', server.name)"
              class="px-2.5 h-7 rounded-md text-dense transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete server"
            >⌫</button>
          </div>
        </div>

        <ul v-if="server.headers && server.headers.length" class="mt-2 space-y-0.5 font-mono text-dense">
          <li
            v-for="(h, i) in server.headers"
            :key="i"
            style="color: var(--semantic-text-dim);"
            :title="`${h.key} = ${h.value}`"
          >
            <span style="color: var(--semantic-text-muted);">• {{ h.key }}</span>
            <span> = {{ maskValue(h.value) }}</span>
          </li>
        </ul>
      </li>
    </ul>
  </div>
</template>

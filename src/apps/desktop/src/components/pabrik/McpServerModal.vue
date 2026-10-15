<script setup lang="ts">
import { computed, onUpdated, ref } from 'vue'

import { testMcpServer, type McpTestResult } from '../../api'
import McpHeadersEditor, { type McpHeader } from './McpHeadersEditor.vue'

/**
 * MCP server modal value — discriminated by `transport`:
 * - 'http'   → uses `url` + `headers`
 * - 'stdio'  → uses `command` + `args` + `env` + `cwd`
 *
 * The UI shows both branches under a transport toggle at the top of
 * the form. The wire shape sent to the backend is the union shape
 * declared in `McpServer` (api/index.ts).
 *
 * NOTE: the HTTP branch is a bespoke dialog (Name + URL + Headers
 * only). It deliberately does NOT reuse LlmConfigModal/LlmConfigForm —
 * those render LLM profile fields (Model, Thinking, Temperature, URL
 * style, API key, compaction overrides) which are meaningless for an
 * MCP server entry and confused users (screenshot: Add MCP server
 * showing "MiniMax-M2.7 / https://api.minimax.io/v1 / Thinking…").
 */
export interface McpServerModalValue {
  name: string
  transport: 'http' | 'stdio'
  url: string
  headers: McpHeader[]
  command: string
  args: string[]
  env: string[]
  cwd: string
  /** When false the agent skips this server. Missing renders as
   *  enabled (checkbox checked). */
  enabled?: boolean
}

const props = withDefaults(
  defineProps<{
    modelValue: McpServerModalValue
    errors?: { name?: string; url?: string; command?: string }
    mode: 'add' | 'edit'
    initialTransport?: 'http' | 'stdio'
  }>(),
  {
    // Default to 'http' for backward compat with legacy callers that
    // never passed an initialTransport.
    initialTransport: 'http',
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: McpServerModalValue]
  cancel: []
  save: []
}>()

// Local edit-state for the stdio textareas (parsed on save). Keeping
// them as raw strings until the user clicks Save means the wire shape
// (newline-separated) round-trips without a parse→stringify roundtrip.
const argsText = ref((props.modelValue.args ?? []).join('\n'))
const envText = ref((props.modelValue.env ?? []).join('\n'))
const cwdLocal = ref(props.modelValue.cwd ?? '')

// If the parent passes a new modelValue (e.g. user picked a different server to edit), re-seed the
// local textareas from it. Prev-identity guard on update — the watcher this replaces was shallow,
// so a new object identity is exactly the trigger.
function reseedFromModelValue(v: McpServerModalValue) {
  argsText.value = (v.args ?? []).join('\n')
  envText.value = (v.env ?? []).join('\n')
  cwdLocal.value = v.cwd ?? ''
  // Editing any field invalidates a previous test result — the server may now be misconfigured even
  // though the prior probe succeeded. Clearing prevents stale "looks good!" badges from lulling the
  // user into saving a broken config.
  testResult.value = null
}

let prevMcpModalValue = props.modelValue
onUpdated(() => {
  if (props.modelValue === prevMcpModalValue) return
  prevMcpModalValue = props.modelValue
  reseedFromModelValue(props.modelValue)
})

// Track which transport the form is currently showing. Initialized from
// props.initialTransport so the parent can default new entries to either
// branch (legacy callers default to 'http').
const transport = ref<'http' | 'stdio'>(props.modelValue.transport ?? props.initialTransport)

// True iff the currently-visible branch's required fields are present.
const stdioValid = computed(() => props.modelValue.command.trim().length > 0)
const httpValid = computed(() => props.modelValue.url.trim().length > 0)

// ─── Test button state ───────────────────────────────────────────────────── `testResult` carries
// the last probe response (or null = "no probe yet"). `testing` is the loading flag — true while
// the HTTP call is in-flight so the button shows a spinner + "Testing…" label.
const testResult = ref<McpTestResult | null>(null)
const testing = ref(false)

// Re-derive whether Test is enabled per branch: - stdio: command present (we send the CURRENT
// textarea contents, not modelValue.args which the parent only refreshes on Save). - http: URL
// present (headers come from modelValue, which updates live via updateHeaders).
const stdioTestValid = computed(() => {
  if (transport.value !== 'stdio') return false
  if (props.modelValue.command.trim().length === 0) return false
  return true
})
const httpTestValid = computed(() => {
  if (transport.value !== 'http') return false
  if (props.modelValue.url.trim().length === 0) return false
  return true
})

async function onTest() {
  if (testing.value) return
  if (transport.value === 'stdio') {
    if (!stdioTestValid.value) return
    testing.value = true
    testResult.value = null
    try {
      // Send the CURRENT textarea contents (not modelValue.args, which
      // is only updated on Save) so the user tests what they see.
      const args = argsText.value
        .split('\n')
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
      const env = envText.value
        .split('\n')
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
      testResult.value = await testMcpServer({
        transport: 'stdio',
        command: props.modelValue.command.trim(),
        args,
        env,
        cwd: cwdLocal.value.trim(),
      })
    } catch (err) {
      // `testMcpServer` always returns a `McpTestResult`; this catch
      // only fires for unexpected exceptions (network down, etc.).
      testResult.value = {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      }
    } finally {
      testing.value = false
    }
    return
  }
  // HTTP branch: probe URL + headers without persisting anything.
  if (!httpTestValid.value) return
  testing.value = true
  testResult.value = null
  try {
    const headers: Record<string, string> = {}
    for (const h of props.modelValue.headers ?? []) {
      if (h.key.trim().length === 0) continue
      headers[h.key.trim()] = h.value
    }
    testResult.value = await testMcpServer({
      transport: 'http',
      url: props.modelValue.url.trim(),
      headers,
    })
  } catch (err) {
    testResult.value = {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    }
  } finally {
    testing.value = false
  }
}

function setTransport(next: 'http' | 'stdio') {
  transport.value = next
  // Switching branches invalidates any prior probe result.
  testResult.value = null
  // Emit so the parent stays in sync.
  emit('update:modelValue', { ...props.modelValue, transport: next })
}

function updateHeaders(h: McpHeader[]) {
  emit('update:modelValue', { ...props.modelValue, headers: h })
}

function updateCommand(e: Event) {
  const value = (e.target as HTMLInputElement).value
  emit('update:modelValue', { ...props.modelValue, command: value })
}

function updateUrl(e: Event) {
  const value = (e.target as HTMLInputElement).value
  emit('update:modelValue', { ...props.modelValue, url: value })
}

function updateEnabled(e: Event) {
  const checked = (e.target as HTMLInputElement).checked
  emit('update:modelValue', { ...props.modelValue, enabled: checked })
}

function onSave() {
  if (transport.value === 'stdio') {
    // Parse stdio textareas into arrays (drop empty lines).
    const args = argsText.value
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    const env = envText.value
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
    // Push the parsed arrays back into modelValue so the parent saves
    // the canonical shape.
    emit('update:modelValue', {
      ...props.modelValue,
      args,
      env,
      cwd: cwdLocal.value.trim(),
    })
    if (!stdioValid.value) {
      // Don't emit save — the parent will see the same modelValue with
      // command still empty and apply its own validation.
      return
    }
    emit('save')
    return
  }
  // HTTP branch: no textarea parsing needed — url/headers already live
  // in modelValue.
  if (!httpValid.value) {
    // Don't emit save — the parent applies its own 'URL is required'
    // validation on the same modelValue.
    return
  }
  emit('save')
}

defineExpose({ onSave })
</script>

<template>
  <!-- HTTP branch: bespoke centered dialog (Name + URL + Headers).
       Deliberately NOT LlmConfigModal — that renders LLM profile
       fields (Model / Thinking / Temperature / URL style / API key /
       compaction overrides) which don't apply to MCP servers. -->
  <Teleport v-if="transport === 'http'" to="body">
    <div
      data-testid="http-modal-backdrop"
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5)"
      @click.self="emit('cancel')"
    >
      <div
        data-testid="http-modal-dialog"
        class="w-full mx-4 max-w-2xl rounded-md flex flex-col"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        role="dialog"
        aria-modal="true"
      >
        <!-- Header: title + close ✕. -->
        <div
          class="flex items-center justify-between px-5 h-12 border-b shrink-0"
          style="border-color: var(--color-border)"
        >
          <h3 class="text-body font-semibold" style="color: var(--semantic-text)">
            {{ mode === 'add' ? 'Add MCP server' : 'Edit MCP server' }}
          </h3>
          <button
            type="button"
            data-testid="http-close-btn"
            @click="emit('cancel')"
            aria-label="Close"
            class="w-7 h-7 flex items-center justify-center text-body"
            style="color: var(--semantic-text-muted)"
          >
            ✕
          </button>
        </div>

        <!-- Body: transport toggle + Name + URL + Headers. -->
        <div class="p-5 space-y-4 overflow-y-auto" style="max-height: 70vh" data-testid="http-form">
          <div class="flex items-center gap-2 text-dense" data-testid="transport-toggle">
            <button
              type="button"
              data-testid="transport-toggle-http"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
              }"
              disabled
            >
              HTTP
            </button>
            <button
              type="button"
              data-testid="transport-toggle-stdio"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
              @click="setTransport('stdio')"
            >
              stdio
            </button>
          </div>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)"
              >Name</label
            >
            <input
              type="text"
              :value="modelValue.name"
              :disabled="mode === 'edit'"
              data-testid="name-input"
              class="w-full px-2.5 h-8 rounded-md text-dense border outline-none"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="
                (e) =>
                  emit('update:modelValue', {
                    ...modelValue,
                    name: (e.target as HTMLInputElement).value,
                  })
              "
            />
          </div>

          <label
            class="flex items-center gap-2 text-dense cursor-pointer"
            style="color: var(--semantic-text)"
          >
            <input
              type="checkbox"
              data-testid="enabled-checkbox"
              :checked="modelValue.enabled ?? true"
              @change="updateEnabled"
            />
            Enabled (agent can call this server)
          </label>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              URL
              <span style="color: var(--color-red)">*</span>
            </label>
            <input
              type="text"
              :value="modelValue.url"
              placeholder="https://example.com/mcp"
              data-testid="url-input"
              class="w-full px-2.5 h-8 rounded-md text-dense font-mono border outline-none"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="updateUrl"
            />
            <p v-if="errors?.url" class="text-dense mt-1" style="color: var(--color-red)">
              {{ errors.url }}
            </p>
          </div>

          <McpHeadersEditor :model-value="modelValue.headers" @update:model-value="updateHeaders" />

          <!-- Test result panel (shared shape with the stdio branch). -->
          <div
            v-if="testResult"
            data-testid="test-result"
            class="px-3 py-2 rounded-md text-dense border"
            :style="
              testResult.ok
                ? {
                    borderColor: 'var(--color-green)',
                    backgroundColor: 'rgba(34, 197, 94, 0.08)',
                    color: 'var(--semantic-text)',
                  }
                : {
                    borderColor: 'var(--color-red)',
                    backgroundColor: 'rgba(239, 68, 68, 0.08)',
                    color: 'var(--semantic-text)',
                  }
            "
          >
            <div class="flex items-center gap-1.5 font-medium">
              <span v-if="testResult.ok" style="color: var(--color-green)">✓</span>
              <span v-else style="color: var(--color-red)">✗</span>
              <span v-if="testResult.ok">
                Connected — {{ testResult.tools.length }} tool{{
                  testResult.tools.length === 1 ? '' : 's'
                }}
                discovered
              </span>
              <span v-else>Connection failed</span>
            </div>
            <div
              v-if="!testResult.ok"
              data-testid="test-error"
              class="mt-1 font-mono text-meta"
              style="color: var(--semantic-text-muted)"
            >
              {{ testResult.error }}
            </div>
            <ul
              v-if="testResult.ok && testResult.tools.length > 0"
              data-testid="test-tools"
              class="mt-1.5 font-mono text-meta space-y-0.5"
            >
              <li
                v-for="tool in testResult.tools"
                :key="tool.name"
                style="color: var(--semantic-text-muted)"
              >
                • {{ tool.name }}
              </li>
            </ul>
          </div>
        </div>

        <!-- Footer: Test + Cancel + Save (mirrors the stdio branch). -->
        <div
          class="flex justify-between gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border)"
        >
          <button
            type="button"
            data-testid="test-btn"
            class="px-3 h-8 rounded-md text-dense border transition-colors duration-150"
            :style="{
              borderColor: 'var(--color-border)',
              color: testing ? 'var(--semantic-text-dim)' : 'var(--semantic-text)',
              backgroundColor: 'transparent',
              opacity: httpTestValid && !testing ? 1 : 0.5,
              cursor: httpTestValid && !testing ? 'pointer' : 'not-allowed',
            }"
            :disabled="!httpTestValid || testing"
            @click="onTest"
          >
            {{ testing ? 'Testing…' : 'Test' }}
          </button>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="cancel-btn"
              class="px-3 h-8 rounded-md text-dense border"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
              @click="emit('cancel')"
            >
              Cancel
            </button>
            <button
              type="button"
              data-testid="save-btn"
              class="px-3 h-8 rounded-md text-dense font-medium border"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
                opacity: httpValid ? 1 : 0.5,
                cursor: httpValid ? 'pointer' : 'not-allowed',
              }"
              :disabled="!httpValid"
              @click="onSave"
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
  </Teleport>

  <!-- stdio branch: bespoke centered dialog. Matches the HTTP branch's
       visual shape exactly (header / body / footer). -->
  <Teleport v-else to="body">
    <div
      data-testid="stdio-modal-backdrop"
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5)"
      @click.self="emit('cancel')"
    >
      <div
        data-testid="stdio-modal-dialog"
        class="w-full mx-4 max-w-2xl rounded-md flex flex-col"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        role="dialog"
        aria-modal="true"
      >
        <!-- Header: title + close ✕. -->
        <div
          class="flex items-center justify-between px-5 h-12 border-b shrink-0"
          style="border-color: var(--color-border)"
        >
          <h3 class="text-body font-semibold" style="color: var(--semantic-text)">
            {{ mode === 'add' ? 'Add MCP server' : 'Edit MCP server' }}
          </h3>
          <button
            type="button"
            data-testid="stdio-close-btn"
            @click="emit('cancel')"
            aria-label="Close"
            class="w-7 h-7 flex items-center justify-center text-body"
            style="color: var(--semantic-text-muted)"
          >
            ✕
          </button>
        </div>

        <!-- Body: transport toggle + the stdio fields. -->
        <div
          class="p-5 space-y-4 overflow-y-auto"
          style="max-height: 70vh"
          data-testid="stdio-form"
        >
          <div class="flex items-center gap-2 text-dense" data-testid="transport-toggle">
            <button
              type="button"
              data-testid="transport-toggle-http"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
              @click="setTransport('http')"
            >
              HTTP
            </button>
            <button
              type="button"
              data-testid="transport-toggle-stdio"
              class="px-3 h-7 rounded-md border transition-colors duration-150"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
              }"
              disabled
            >
              stdio
            </button>
          </div>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)"
              >Name</label
            >
            <input
              type="text"
              :value="modelValue.name"
              :disabled="mode === 'edit'"
              data-testid="name-input"
              class="w-full px-2.5 h-8 rounded-md text-dense border outline-none"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="
                (e) =>
                  emit('update:modelValue', {
                    ...modelValue,
                    name: (e.target as HTMLInputElement).value,
                  })
              "
            />
          </div>

          <label
            class="flex items-center gap-2 text-dense cursor-pointer"
            style="color: var(--semantic-text)"
          >
            <input
              type="checkbox"
              data-testid="enabled-checkbox"
              :checked="modelValue.enabled ?? true"
              @change="updateEnabled"
            />
            Enabled (agent can call this server)
          </label>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Command
              <span style="color: var(--color-red)">*</span>
            </label>
            <input
              type="text"
              :value="modelValue.command"
              placeholder="mcp-hello-world"
              data-testid="command-input"
              class="w-full px-2.5 h-8 rounded-md text-dense font-mono border outline-none"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="updateCommand"
            />
            <p v-if="errors?.command" class="text-dense mt-1" style="color: var(--color-red)">
              {{ errors.command }}
            </p>
          </div>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Arguments <span style="color: var(--semantic-text-dim)">(one per line)</span>
            </label>
            <textarea
              v-model="argsText"
              rows="3"
              placeholder="server.js&#10;--port&#10;3001"
              data-testid="args-textarea"
              class="w-full px-2.5 py-1.5 rounded-md text-dense font-mono border outline-none resize-y"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
            ></textarea>
          </div>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Environment
              <span style="color: var(--semantic-text-dim)">(KEY=VALUE, one per line)</span>
            </label>
            <textarea
              v-model="envText"
              rows="2"
              placeholder="NODE_ENV=production"
              data-testid="env-textarea"
              class="w-full px-2.5 py-1.5 rounded-md text-dense font-mono border outline-none resize-y"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
            ></textarea>
          </div>

          <div>
            <label class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Working directory <span style="color: var(--semantic-text-dim)">(optional)</span>
            </label>
            <input
              v-model="cwdLocal"
              type="text"
              placeholder="/absolute/path"
              data-testid="cwd-input"
              class="w-full px-2.5 h-8 rounded-md text-dense font-mono border outline-none"
              style="
                background-color: var(--semantic-content-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
            />
          </div>

          <!-- Test result panel. Shows green pill + tool list on
               success, red banner with the server's error message
               on failure, and a "not yet tested" hint before the
               user clicks Test. Cleared whenever any form field
               changes (watch on modelValue) so stale results don't
               survive a re-edit. -->
          <div
            v-if="testResult"
            data-testid="test-result"
            class="px-3 py-2 rounded-md text-dense border"
            :style="
              testResult.ok
                ? {
                    borderColor: 'var(--color-green)',
                    backgroundColor: 'rgba(34, 197, 94, 0.08)',
                    color: 'var(--semantic-text)',
                  }
                : {
                    borderColor: 'var(--color-red)',
                    backgroundColor: 'rgba(239, 68, 68, 0.08)',
                    color: 'var(--semantic-text)',
                  }
            "
          >
            <div class="flex items-center gap-1.5 font-medium">
              <span v-if="testResult.ok" style="color: var(--color-green)">✓</span>
              <span v-else style="color: var(--color-red)">✗</span>
              <span v-if="testResult.ok">
                Connected — {{ testResult.tools.length }} tool{{
                  testResult.tools.length === 1 ? '' : 's'
                }}
                discovered
              </span>
              <span v-else>Connection failed</span>
            </div>
            <div
              v-if="!testResult.ok"
              data-testid="test-error"
              class="mt-1 font-mono text-meta"
              style="color: var(--semantic-text-muted)"
            >
              {{ testResult.error }}
            </div>
            <ul
              v-if="testResult.ok && testResult.tools.length > 0"
              data-testid="test-tools"
              class="mt-1.5 font-mono text-meta space-y-0.5"
            >
              <li
                v-for="tool in testResult.tools"
                :key="tool.name"
                style="color: var(--semantic-text-muted)"
              >
                • {{ tool.name }}
              </li>
            </ul>
          </div>
        </div>

        <!-- Footer: Test + Cancel + Save.
             The Test button is on the LEFT so the primary action
             (Save) stays anchored at the bottom-right. Test is
             disabled when command is empty OR a probe is already
             in flight, so the user can't fire concurrent probes. -->
        <div
          class="flex justify-between gap-2 px-5 h-14 border-t shrink-0 items-center"
          style="border-color: var(--color-border)"
        >
          <button
            type="button"
            data-testid="test-btn"
            class="px-3 h-8 rounded-md text-dense border transition-colors duration-150"
            :style="{
              borderColor: 'var(--color-border)',
              color: testing ? 'var(--semantic-text-dim)' : 'var(--semantic-text)',
              backgroundColor: 'transparent',
              opacity: stdioTestValid && !testing ? 1 : 0.5,
              cursor: stdioTestValid && !testing ? 'pointer' : 'not-allowed',
            }"
            :disabled="!stdioTestValid || testing"
            @click="onTest"
          >
            {{ testing ? 'Testing…' : 'Test' }}
          </button>
          <div class="flex gap-2">
            <button
              type="button"
              data-testid="cancel-btn"
              class="px-3 h-8 rounded-md text-dense border"
              style="
                border-color: var(--color-border);
                color: var(--semantic-text-muted);
                background-color: transparent;
              "
              @click="emit('cancel')"
            >
              Cancel
            </button>
            <button
              type="button"
              data-testid="save-btn"
              class="px-3 h-8 rounded-md text-dense font-medium border"
              :style="{
                borderColor: 'var(--color-violet)',
                backgroundColor: 'var(--color-violet)',
                color: 'var(--semantic-bg)',
                opacity: stdioValid ? 1 : 0.5,
                cursor: stdioValid ? 'pointer' : 'not-allowed',
              }"
              :disabled="!stdioValid"
              @click="onSave"
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
/** WebSearchSection — the `web_search` provider list in Settings. Sits on the same tab as
 * McpServersSection: both answer "where does the agent reach outside this machine". */
import EmptyState from './EmptyState.vue'
import SettingsSkeleton from './SettingsSkeleton.vue'
import type { WebSearchProviderRow } from './webSearchProviders'

const props = withDefaults(
  defineProps<{
    modelValue: WebSearchProviderRow[]
    /** Per-row message keyed by `WebSearchProviderRow.id`. */
    errors?: Record<string, string>
    /** True while the parent's config fetch is in flight. */
    loading?: boolean
  }>(),
  { errors: () => ({}), loading: false },
)

const emit = defineEmits<{
  'update:modelValue': [rows: WebSearchProviderRow[]]
  add: []
}>()

function patch(id: string, changes: Partial<WebSearchProviderRow>) {
  emit(
    'update:modelValue',
    props.modelValue.map((row) => (row.id === id ? { ...row, ...changes } : row)),
  )
}

function updateField(id: string, field: keyof WebSearchProviderRow, e: Event) {
  patch(id, { [field]: (e.target as HTMLInputElement).value })
}

function toggleEnabled(row: WebSearchProviderRow) {
  patch(row.id, { enabled: !row.enabled })
}

function removeRow(id: string) {
  emit(
    'update:modelValue',
    props.modelValue.filter((row) => row.id !== id),
  )
}
</script>

<template>
  <div class="space-y-4" data-testid="web-search-section">
    <p class="text-dense leading-relaxed max-w-2xl" style="color: var(--semantic-text-muted)">
      Web search providers the agent can call. Each provider has a name, the
      <strong style="color: var(--semantic-text)">pinned host</strong> the key is allowed to reach,
      and the curl command copied from that provider's documentation — put
      <code style="font-family: var(--font-mono)">{key}</code> where the credential goes. The agent
      finds these through
      <code style="font-family: var(--font-mono)">list_web_search_providers</code>.
    </p>

    <div class="flex justify-end">
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-dense font-medium border transition-colors duration-150"
        style="
          border-color: var(--color-violet);
          color: var(--color-violet);
          background-color: transparent;
        "
      >
        + Add provider
      </button>
    </div>

    <SettingsSkeleton v-if="loading" test-id="web-search-loading-skeleton" />

    <EmptyState
      v-else-if="modelValue.length === 0"
      glyph="⌕"
      title="No web search providers yet"
      description="Add a provider to let the agent search the web — paste the host and the curl command from that provider's docs."
      cta-label="+ Add provider"
      :cta-action="() => emit('add')"
    />

    <ul v-else class="space-y-2" data-testid="web-search-list">
      <li
        v-for="row in modelValue"
        :key="row.id"
        :data-row-id="row.id"
        :data-testid="`web-search-row-${row.id}`"
        class="px-4 py-3 rounded-md space-y-2"
        :class="{ 'opacity-60': !row.enabled }"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border)"
      >
        <div class="flex items-center justify-between gap-3">
          <div class="flex-1 min-w-0">
            <div
              class="text-body font-medium flex items-center gap-2"
              style="color: var(--semantic-text)"
            >
              <span data-testid="row-name-label">{{ row.name || 'New provider' }}</span>
              <span
                v-if="!row.enabled"
                data-testid="disabled-pill"
                class="text-micro px-1.5 h-4 inline-flex items-center rounded font-medium uppercase tracking-wide"
                style="color: var(--color-red); border: 1px solid var(--color-red)"
                >Disabled</span
              >
              <span
                v-if="row.key"
                data-testid="key-set-pill"
                class="text-micro px-1.5 h-4 inline-flex items-center rounded font-medium uppercase tracking-wide"
                style="color: var(--semantic-text-muted); border: 1px solid var(--color-border)"
                >Key set</span
              >
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              type="button"
              data-testid="toggle-btn"
              @click="toggleEnabled(row)"
              :aria-pressed="row.enabled"
              title="Enable/Disable provider"
              :aria-label="row.enabled ? 'Disable provider' : 'Enable provider'"
              class="w-9 h-5 rounded-full border transition-colors duration-150 flex items-center px-0.5"
              :style="
                row.enabled
                  ? {
                      borderColor: 'var(--color-violet)',
                      backgroundColor: 'var(--color-violet)',
                      justifyContent: 'flex-end',
                    }
                  : {
                      borderColor: 'var(--color-border)',
                      backgroundColor: 'transparent',
                      justifyContent: 'flex-start',
                    }
              "
            >
              <span
                class="w-3.5 h-3.5 rounded-full"
                :style="
                  row.enabled
                    ? { backgroundColor: 'var(--semantic-bg)' }
                    : { backgroundColor: 'var(--semantic-text-dim)' }
                "
              ></span>
            </button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="removeRow(row.id)"
              class="px-2.5 h-7 rounded-md text-dense"
              style="color: var(--color-red)"
              :aria-label="`Remove provider ${row.name}`"
            >
              ⌫
            </button>
          </div>
        </div>

        <div class="flex gap-2">
          <label class="flex-1 min-w-0">
            <span class="block text-dense font-medium mb-1" style="color: var(--semantic-text)"
              >Name</span
            >
            <input
              type="text"
              :value="row.name"
              placeholder="tinyfish"
              data-testid="name-input"
              class="w-full px-2.5 h-8 rounded-md text-dense border outline-none"
              style="
                background-color: var(--semantic-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="(e) => updateField(row.id, 'name', e)"
            />
          </label>
          <label class="flex-1 min-w-0">
            <span class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Pinned URL <span style="color: var(--color-red)">*</span>
            </span>
            <input
              type="text"
              :value="row.url"
              placeholder="https://api.search.tinyfish.ai"
              data-testid="url-input"
              class="w-full px-2.5 h-8 rounded-md text-dense font-mono border outline-none"
              style="
                background-color: var(--semantic-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="(e) => updateField(row.id, 'url', e)"
            />
          </label>
        </div>

        <div class="flex gap-2">
          <label class="flex-1 min-w-0">
            <span class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Key <span style="color: var(--semantic-text-dim)">(optional)</span>
            </span>
            <input
              type="password"
              :value="row.key"
              autocomplete="off"
              placeholder="leave empty for a self-hosted provider"
              data-testid="key-input"
              class="w-full px-2.5 h-8 rounded-md text-dense font-mono border outline-none"
              style="
                background-color: var(--semantic-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="(e) => updateField(row.id, 'key', e)"
            />
          </label>
          <label class="flex-1 min-w-0">
            <span class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
              Description <span style="color: var(--semantic-text-dim)">(optional)</span>
            </span>
            <input
              type="text"
              :value="row.description"
              placeholder="Best for news. Free tier 1000/day."
              data-testid="description-input"
              class="w-full px-2.5 h-8 rounded-md text-dense border outline-none"
              style="
                background-color: var(--semantic-bg);
                border-color: var(--color-border);
                color: var(--semantic-text);
              "
              @input="(e) => updateField(row.id, 'description', e)"
            />
          </label>
        </div>

        <label class="block">
          <span class="block text-dense font-medium mb-1" style="color: var(--semantic-text)">
            curl <span style="color: var(--color-red)">*</span>
          </span>
          <textarea
            :value="row.curl"
            rows="2"
            spellcheck="false"
            placeholder='https://api.search.tinyfish.ai?query=PLACEHOLDER -H "X-API-Key: {key}"'
            data-testid="curl-textarea"
            class="w-full px-2.5 py-1.5 rounded-md text-dense font-mono border outline-none resize-y"
            style="
              background-color: var(--semantic-bg);
              border-color: var(--color-border);
              color: var(--semantic-text);
            "
            @input="(e) => updateField(row.id, 'curl', e)"
          ></textarea>
        </label>

        <!-- Backend rejection / pre-flight message for THIS row. Rendered
             verbatim: a provider the backend refuses must not collapse
             into a generic "save failed" toast the user cannot act on. -->
        <p
          v-if="errors[row.id]"
          :data-testid="`row-error-${row.id}`"
          class="text-dense"
          style="color: var(--color-red)"
        >
          {{ errors[row.id] }}
        </p>
      </li>
    </ul>
  </div>
</template>

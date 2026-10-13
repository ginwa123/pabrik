# Simplify the Edit-profile dialog, and source model defaults from models.dev

**Status:** plan only — nothing implemented. **Wireframe:** `docs/wireframes/profile-editor-models-dev.html`
**Base:** `main` @ `69c6df2d` · **Task:** `task_1791835298377_3`

---

## 1. What the user asked for

"i want simplify this settings profiles — also implement models.dev to get defaults,
value compaction token window context."

Two things, and they are the same thing: the dialog (screenshot: `deepseek auto` —
Name, Model, Base URL, Thinking, Temperature, URL style, Reasoning effort, API key,
then *Compaction overrides* with two checkboxes and a slider) asks the user to supply
facts the app should already know. models.dev is where those facts live.

---

## 2. What is actually wrong today (verified, not guessed)

### 2.1 The real bug — every non-MiniMax profile compacts at the wrong window

`src/modules/agent/LLMModels.zig:22` `getModelTokenCount` knows exactly **two** models:

```zig
if (std.mem.eql(u8, model_name, MINIMAX_2_7.name)) return MINIMAX_2_7.token_count; // 200_000
if (std.mem.eql(u8, model_name, MINIMAX_3.name))   return MINIMAX_3.token_count;   // 500_000
return 200000;  // "Default fallback (e.g., 128k tokens)"
```

That function is the last step of the context-window cascade
(`src/modules/config/Config.zig:2742` `maxCapacityForModel`, step 4) and of the
compaction threshold (`Config.zig:2764`, step 4 = 80).

So for the profile in the screenshot:

| | value |
|---|---|
| `deepseek-flash` real context window (models.dev `limit.context`) | **1,000,000** |
| what pabrik believes with no override | **200,000** |
| where it compacts | 80% × 200k = **160,000** |
| where it should compact | 80% × 1M = **800,000** |

The hand-typed `1000000` in the *Max capacity (tokens)* field is the **only** reason
that profile compacts correctly, and nothing on the screen says so. Delete the field and
the same profile silently throws away ~4/5 of its window. This is not a UI nit; it is the
compaction bug the models.dev work exists to fix.

### 2.2 The fallback the help text promises does not exist

`LlmConfigForm.vue:352` and `:387` say *"Falls back to top-level defaults → built-in."*
The top-level fields are `LlmConfig.max_capacity_token_model` (`Config.zig:173`) and
`LlmConfig.compaction_threshold_percent` (`Config.zig:179`) — cascade steps 3.

**No component writes them.** `rg max_capacity_token_model src/apps/desktop/src` returns
the TypeScript type (`api/index.ts:4917`) and a write-through spread
(`PabrikConfigEditor.vue:508`) — no input, no slider, no section. The Defaults tab that
used to own them was removed by plan `2026-08-24-config-simplify-remove-defaults`, and the
comment at `PabrikConfigEditor.vue:1319-1322` still claims they live there. So the dialog
points at a setting the user cannot reach.

### 2.3 Three fields encode one decision

`model` + `base_url` + `url_style` are free-text + free-text + 3-way select, and nothing
validates them against each other. They are one decision ("which provider am I talking
to, and what body shape does it speak") spread over three controls.

### 2.4 Capability controls are gated on the wire shape, not the model

`LlmConfigForm.vue:134-137`: `thinking_budget_tokens` shows for `url_style === 'anthropic'`,
`reasoning_effort` for `url_style.startsWith('openai')`. A model that ignores
`reasoning_effort` still gets a live **Reasoning effort** dropdown; an Anthropic-shaped
URL gets a budget field even for a model with no extended thinking.

### 2.5 Compaction is expressed twice

Per-profile overrides in the modal (`LlmConfigForm.vue:332-415`) *and* a summary line in
the profile row (`ProfilesSection.vue:80-90` `compactionSummary`) that recomputes from the
raw fields and prints `default (80%) @ default` — which reads as "nothing is going on"
when in fact 200k × 80% is about to happen.

---

## 3. What models.dev gives us

`https://models.dev/api.json`, fetched 2026-10-13:

| | |
|---|---|
| size | **5,451,834 bytes** raw JSON |
| providers | **227** |
| models | **8,562** (8,402 carry a context limit) |
| CORS | `access-control-allow-origin: *` (so a webview `fetch()` would work) |
| cache | `cf-cache-status: HIT`, `etag` present |

Only a fraction is needed:

| models.dev | pabrik field | coverage / notes |
|---|---|---|
| `provider.api` | `base_url` | **202 of 227**. `anthropic` has none ⇒ keep a tiny built-in map for headliners. |
| `provider.npm` | `url_style` | 227/227. `@ai-sdk/anthropic`, `@ai-sdk/google-vertex/anthropic` ⇒ `anthropic`; everything else ⇒ `openai`. 6,276 models are `@ai-sdk/openai-compatible`. |
| `provider.env` | API-key placeholder | `DEEPSEEK_API_KEY`. Documentation only — never read the env. |
| `model.limit.context` | `max_capacity_tokens` | the point of the exercise. `deepseek-flash` ⇒ 1,000,000. |
| `model.limit.output` | max output tokens | `deepseek-flash` ⇒ 393,216. Today `Agent.maxTokens` is a flat **4096** (`Agent.zig:1327`). |
| `model.reasoning` + `model.reasoning_options` | `thinking` / `reasoning_effort` | `[{"type":"toggle"},{"type":"effort","values":["low","high","max"]}]`, `[{"type":"budget_tokens","min":1024}]` — both shapes pabrik already speaks. |
| `model.temperature` | whether to show the Temperature field | boolean. |
| `model.cost{input,output,cache_read,cache_write}` | read-only info | `deepseek-flash` ⇒ 0.15 / 0.6 per Mtok. |
| `model.attachment`, `model.modalities` | read-only info | images / pdf. |

**Trimmed payload ≈ 2.3 MB** (measured, compact JSON, keeping only the fields above).
Fine as a cache file; a bad thing to commit.

---

## 4. Design

### 4.1 One owner, split three ways

`session_llm_config.zig`'s rule applies: one owner per question. The question here
("what do we know about this model?") is answered by three files with one job each:

| file | job | testability |
|---|---|---|
| `src/agentic_loop/model_catalog.zig` | trim models.dev's payload, parse it, look a model up | **std-only**, so `zig test <file>` runs it standalone in ~2s |
| `src/models/model_catalog_store.zig` | snapshot to / load from the DB | in-memory SQLite, like every other store |
| `src/agentic_loop/model_catalog_refresh.zig` | the libcurl fetch and the hourly timer | functional harness |

**The cache lives in the DATABASE — decided with the user, and different from this plan's
first draft.** Migration 106 adds `model_catalog_providers` / `model_catalog_models` /
`model_catalog_meta`; the store snapshots to and loads from them. A JSON file *plus* a table
would be two sources of truth for the same 8,562 rows, and the first time they disagreed
nobody could say which was lying. There is no file cache.

The in-memory `Catalog` is a projection of those tables, and it exists because the
compaction decision reads a context window on **every loop iteration** — a query per
iteration is not acceptable.

**Boot reads the DB only; it never touches the network.** The fetch runs on a detached
thread, hourly. `saveCatalog` always runs *before* the index swap, so a failed fetch or a
failed write leaves every session compacting against exactly the numbers it had a moment
earlier. An empty catalog is refused outright rather than traded for a good snapshot.

### 4.2 Backend resolution — add a catalog step, keep every pure function pure

`Config.zig` `maxCapacityForModel` (`:2742`) keeps its shape and gains one step:

```
1. sub_agent.max_capacity_tokens
2. profile.max_capacity_tokens
3. defaults.max_capacity_token_model
4. NEW  catalog.lookup(provider, model).context_window
5. LLMModels.getModelTokenCount(model)        // 200k built-in, unchanged
```

`LLMModels.getModelTokenCount` stays pure and untouched (all 14 existing tests keep
passing); a new `getModelTokenCountFrom(catalog, provider, model)` is the catalog-aware
sibling. `compactionThresholdPercent` needs no catalog — 80 is a policy, not a model fact.

### 4.3 HTTP surface (`src/http_routes.zig`, all under the existing `authed` group)

| route | purpose |
|---|---|
| `GET /api/models/catalog?q=&provider=&limit=` | trimmed catalog for the picker. Filtered + paged server-side — never ship 2.3 MB to the webview on open. |
| `GET /api/models/resolve?model=&provider=&base_url=` | the single call the modal makes: `{ context_window, output_tokens, url_style, base_url, reasoning, temperature, cost, source: "catalog"\|"builtin", catalog: "fresh"\|"stale"\|"absent" }` |
| `POST /api/models/refresh` | explicit fetch + write + report `{ok, providers, models, fetched_at}` or a real error envelope. |

Route-order note: these are all literals under `/api/models/…`; check no `/api/models/:param`
pattern is registered before them (`matchRoute` walks registration order — a literal
registered after a wildcard is captured by the wildcard).

### 4.4 UI — the aim is "two fields and one line"

`LlmConfigForm.vue` is rebuilt around the principle that **the face of the dialog shows only
the two numbers that change behaviour: the context window, and where compaction fires.**
Everything else is a fact the user is not choosing, and it moves to the one place a default
already belongs — `Advanced`.

The final layout (v2 in the wireframe; v1, the 7-row "Resolved from models.dev" panel, is kept
in the same file for comparison and is **not** the target):

```
Edit profile            deepseek auto        ✕
────────────────────────────────────────────────
Model *
[ deepseek-flash                         ▾ ]
DeepSeek · 1M context · compacts at 800k · $0.15/$0.60 · models.dev

API key *
[ •••••••••••••••••••••••••••••• ]      ○

▸ Advanced                    nothing overridden
────────────────────────────────────────────────
Test                     Cancel      Save
```

- **Two controls in Edit mode** (Model, API key). Today the dialog exposes 12.
- **One fact line** under the model: provider · context window · where compaction fires ·
  price · provenance. It answers "what will this profile actually do" without a table, and it
  is the only place a number appears.
- **Name leaves the form.** It is already read-only in Edit mode — a whole row spent saying
  "you cannot change this". It moves into the dialog title. Add mode keeps the field.
- **Zero helper text on the face.** Each Advanced field's placeholder *is* its documentation
  (`inherit — openai`, `inherit — 80%`, `inherit — 1,000,000`), so the three copies of
  "Falls back to top-level defaults → built-in" are deleted rather than reworded.
- **Nothing is removed.** All 7 overrides still exist, still write the same JSON keys,
   still resolve through the same cascade.

`Advanced`, grouped so it can be scanned rather than read:

| group | fields |
|---|---|
| Connection | `Base URL` (inherit — provider.api), `Body shape` (inherit — openai / openai-response / anthropic) |
| Behaviour | `Thinking` (inherit — Auto), `Effort` (label names the model's own options), `Temperature` (inherit — auto) |
| Compaction | `Threshold %` (inherit — the global default), `Context window` (inherit — catalog) |

One sentence explains the whole section ("every field inherits until you type in it; ✕ goes back
to inheriting") instead of seven per-field explanations. The override checkboxes are gone —
empty already means inherit — and a ✕ clears a filled field explicitly.

`ProfilesSection.vue` gets the same treatment — 4 lines per row to 2:

| | |
|---|---|
| **now** | `deepseek auto · active` / `deepseek-flash · https://opencode.ai/zen/go/v1/chat/completions` / `▾ 2 sub-agents` / `Compaction: 97% @ 1000k tokens` |
| **v2** | `deepseek auto · active` + `2 sub-agents` trailing / `deepseek-flash · 1M context · compacts at 800k` |

The base URL becomes a tooltip — it is an implementation detail of the model choice, and every
row printing a full endpoint was the noisiest thing in the list. `compactionSummary`
(`ProfilesSection.vue:80-90`) stops printing `default (80%) @ default` and states the numbers
that actually apply.

Both honest states are visible, not silent:

- unknown model ⇒ the line turns amber: `unknown model · set the context window in Advanced`
- catalog absent (offline) ⇒ `200k context (built-in)` — today's behaviour, said out loud

### 4.5 What deliberately does **not** change

- **The wire format.** `max_capacity_tokens` / `compaction_threshold_percent` /
  `thinking_budget_tokens` stay `number | null`. An **empty field must serialize to `null`,
  never `""`** — an empty slice binds as SQL NULL through this codebase's SQLite layer, and
  a cleared override has to round-trip as `null`.
- **No config migration.** An existing `config.json` is byte-identical after this change;
  only *resolved* values differ (correctly, for non-MiniMax models).
- **The catalog never writes into a profile.** It supplies defaults at the existing
  resolution points, so one refresh corrects every profile instead of leaving stale
  hand-typed numbers behind.

---

## 5. Phased implementation

| phase | scope | files |
|---|---|---|
| **P1** | catalog module + cache file + trim + lookup. No HTTP, no UI. | `src/agentic_loop/model_catalog.zig` (new), `src/root.zig` (export + test import) |
| **P2** | wire the catalog into the resolution cascade; `getModelTokenCountFrom`. | `src/modules/config/Config.zig:2742`, `src/modules/agent/LLMModels.zig` |
| **P3** | three routes + refresh. | `src/http_routes.zig`, `src/http_handlers/model_catalog_*.zig` (new) |
| **P4** | UI: combobox, the one fact line, grouped Advanced, name into the title; delete the checkboxes and the helper prose. | `LlmConfigForm.vue`, `LlmConfigModal.vue` (title), `PabrikConfigEditor.vue:568-605` (seeding) |
| **P4b** | Profile-row summary: 4 lines → 2, effective window instead of `default`. | `ProfilesSection.vue:80-90` |
| **P5** | the orphaned global defaults (decision D3). | Settings → General block + `PabrikConfigEditor.vue` |

P1–P3 are independently shippable: with the backend catalog in place but the old UI, the
compaction bug is already fixed for every profile that leaves `max_capacity_tokens` null.

---

## 6. Verification (functional, not source-greps)

Per this repo's rule: **no test may open a `.zig` file under `src/` and search its text.**
A `test` block calls the code and asserts what comes back.

- **Unit (in-memory SQLite/JSON, no network)** — `model_catalog.zig`:
  trim from a fixture slice → lookup by (provider, model) → `context_window == 1_000_000`
  for `deepseek-flash`; unknown model ⇒ `null` (not a fabricated number); a **corrupt**
  cache file ⇒ a named error, not an empty catalog; a provider without `api` ⇒
  `base_url == null` while `url_style == "anthropic"`.
- **Unit** — `Config.maxCapacityForModel`: a profile with `max_capacity_tokens = null`
  and a catalog that knows the model resolves to the catalog value, pre-empting the 200k
  built-in; the user's typed override still wins over the catalog (positive control).
- **Functional (Zig harness, isolated tmpdir HOME, port never 8081)** —
  `tests/functional/model_catalog_test.zig`:
  1. seed `models-dev.json` in the tmpdir HOME → `GET /api/models/resolve?model=deepseek-flash`
     returns `1_000_000` and `source: "catalog"`;
  2. delete the cache → same request returns `200_000`, `source: "builtin"`,
     `catalog: "absent"` — the **absence must be visible in the payload**, not swallowed;
  3. `POST /api/models/refresh` with the upstream pointed at a **local stub HTTP server**
     (never models.dev from CI) → 200 + cache file written; stub returning garbage ⇒ a
     non-2xx with a real error, and the previous cache left intact.
- **Frontend (vitest)** — `LlmConfigForm.spec.ts` (extend the existing file, do not fork):
  typing a catalog-known model fills the derived strip and emits
  `max_capacity_tokens: null` (**not** a materialized number); clearing a previously-set
  override emits `null` and never `""`; an unknown model shows the manual state; a
  non-reasoning model does not render the effort dropdown.
- **Manual**: `zig build test --summary all` + the frontend build, in the worktree.

---

## 7. Decisions to confirm

- **D1 — where the catalog lives.** **DECIDED (user): the database.** Migration 106 + a
  store, no file cache. A committed snapshot was rejected (2.3 MB that rots), and
  frontend-only `fetch()` was rejected because the server-side compaction bug would survive it.
- **D2 — when we refresh.** **DECIDED (user): in the background, every hour, non-blocking.**
  Boot installs the cached snapshot with no network call at all. The manual
  `POST /api/models/refresh` is for "I just changed providers and do not want to wait", not
  the primary path.
- **D3 — the orphaned top-level defaults.** *Recommend: put one "Compaction" block back in
  Settings → General* (threshold %, optional forced window) as the single global home.
  Alternative: delete `max_capacity_token_model` / `compaction_threshold_percent` from the
  cascade as dead UI — but workspace overlays and hand-edited configs already use them.
- **D4 — model entry stays a combobox, not a select.** A strict dropdown breaks self-hosted
  endpoints and the screenshot's `opencode.ai/zen` URL, which is not in the catalog.
- **D5 — output cap + price on the fact line.** *Recommend: price yes, output cap no.*
  Nothing reads an output cap today (`Agent.maxTokens` is a flat 4096), so printing 393,216
  would be a number that changes nothing — and the fact line is worth keeping to four tokens.
  Pricing stays read-only: per-provider, and it goes stale.
- **D6 — workspace scope.** Workspace settings can override `profiles_models`; does a
  workspace get its own catalog cache? *Recommend: one machine-wide cache* — it is model
  metadata, not user data.

---

## 8. Risks

- **Offline / air-gapped.** No cache ⇒ catalog absent ⇒ today's 200k built-in. The UI must
  *say* that (`catalog unavailable — context window is the 200k built-in`) instead of
  showing a confidently wrong number.
- **Provider/model ambiguity.** `deepseek-flash` exists under several providers with
  different limits. Resolution needs the provider, not just `model`; a bare model name must
  pick a ranked match and name it in the UI.
- **Upstream trust.** A wrong `limit.context` upstream silently changes when pabrik
  compacts. A user-typed override must always win, and the resolved source must be visible
  next to the number.
- **Staleness of the trimmed schema.** models.dev is an external schema; the trim step must
  tolerate missing/renamed fields (unknown ⇒ `null`, never a default) and the cache must
  carry a schema version so a shape change invalidates rather than mis-parses.

---

## 9. Non-goals

- Changing where compaction happens, or how the compaction prompt is built.
- A pricing/billing surface, model leaderboards, or model switching outside profiles.
- Migrating any existing `config.json`.
- Touching `session_llm_config.zig`'s per-owner/per-workspace resolution.

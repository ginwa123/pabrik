# git in the guest — §2.1's seven host call sites, and criterion 9

Card `task_1792319132647116482`, branch `worktree/git-in-guest-1792319132647116482`,
based on `worktree/workspace-is-a-vm-from-microvm-1792245526062` (PR #983).
This is the record §29's "What this does NOT do" pointed at: *the host still runs
`git` on a tenant tree*.

## 1. The rule, and what it does not cover

§2.1: *"The API process never executes `git`/`gh` with a tenant-controlled tree
as its working directory or `-C` target."* Criterion 9 restates it and asks for a
test: *"tested with a fixture repo carrying a `core.fsmonitor` canary."*

Appendix C enumerates seven call sites. Those seven — minus `list_directory.zig`,
which another card owns — are what this change routes. §2.1's rule is *broader*
than Appendix C, and §5 below inventories what that leaves: ~40 further host
`git` argv sites and every host `gh`/`glab` invocation. This change closes the
Appendix C set, not the rule.

## 2. The seam — no new protocol

The route already existed: the `exec` RPC the `command` tool uses
(`policy.shellArgv` + `cwd_rel`). What was missing was a way for a call site that
is not a shell command to ask for it. That is four additions to
`src/agentic_loop/workspace_fs.zig`, the module that was already the seam for the
file tools:

| addition | what it answers |
|---|---|
| `routeForSession(alloc, db, session_id) Route` | guest / host / **unavailable** for a session's tree |
| `routeForPath(alloc, db, path) Route` | the same, for a caller that has a path and no session (the HTTP handlers) |
| `Fs.runGit(abs_dir, args, timeout, max_out)` | `git <git_hardening.CONFIG_ARGS> <args>` **inside the guest**, cwd = `abs_dir`, no `-C`: the host path never crosses |
| `Fs.guestAbs(abs)` | the `/workspace/...` path a host path names — the guest's own vocabulary, for an argv that will run there |

`Route` is a three-way union on purpose. "No VM" is a *value*, not `null`, because
`null` is already taken by "the host is the right answer": collapsing the two is
exactly the bug criterion 9 describes. A caller that must fail closed matches
`.unavailable` first, and every site below does.

`src/agentic_loop/workspace_scope.zig` gained `resolveWorkspaceForPath` — the
longest-prefix-as-slash-boundary rule `resolveWorkspaceId` already applies to a
session's cwd, now available for a bare directory.

## 3. The call sites

| site | what a tenant repo could do | what changed |
|---|---|---|
| `agentic_loop/git_state.zig` (`fetchGitState`, the git chip) | `core.fsmonitor` → **arbitrary code on the host** | new `fetchGitStateFor(alloc, io, db, session_id, dir)`; the five questions (`rev-parse --show-toplevel`, `--git-common-dir`, `--short HEAD`, `branch --show-current`, `status --porcelain`) go to the guest under `--saas`. Wired in `workflow_compact_message.zig`. |
| `modules/agent/tools/set_git_worktree.zig` (`worktree add`) | the repo's `post-checkout` hook | `runGitWorktreeAdd` takes a `guest`; the worktree path is named by its **guest** path (`Fs.guestAbs`), which refuses anything outside the workspace. |
| same file, `worktree list --porcelain` | same class | `guestWorktreeList` — the listing crosses in one bounded reply. |
| same file, `worktree remove --force` | same class | `guestWorktreeRemove`, run from the repo the worktree belongs to instead of `.cwd = .inherit`. |
| `modules/system_folder/system_folder.zig` (`check-ignore`, batched) | config parsing on a path the agent can aim anywhere | `batchIgnoredNames` resolves a route for its directory and asks `Fs.gitCheckIgnore`; the guest answers **per name**, so no output is matched back onto the input by string. |
| `http_handlers/git_pr_status.zig` (`rev-parse --git-dir`) | tenant-controlled input to a host process | `isGitRepository(…, route, path)`. |
| same file (`remote get-url origin`) | same | `remoteOriginUrl(…, route, path)`. |
| `http_handlers/git_pr_conflicts.zig` (`rev-parse`, `merge-tree`) | same | one `runGit(alloc, io, route, path, args)` for the whole feature — the four callers (`refExists`, `resolveBaseRef`, `revParseShort`, `useCase`) already funnelled through it. |
| `modules/agent/tools/status_pull_request.zig` (`remote get-url origin`) | same | `providerFromOrigin(…, guest)`; the host half moved to `hostOriginUrl`, the guest half to `guestOriginUrl`. |

`list_directory.zig` is **untouched**: its per-entry `git check-ignore` is the
fs.write/fs.walk card's business, and that card routes the tool into the guest,
which removes the host call with it. Cross-card dependency, recorded below.

`src/helpers/git_hardening.zig` stays, unchanged, as defence in depth for local
mode — and it is what the guest argv still carries.

## 4. Fail-closed, and local mode

Three states, each with exactly one answer:

* **Local mode** (`--saas` off, or the backend cannot run) — `Route.host`, and
  every host code path is byte-identical to before: same argv, same cwd, same
  error strings, same exit-code handling. Routing is inert, not merely unused.
* **`--saas` with a reachable guest** — the guest's git, over the exec RPC.
* **`--saas` with no VM answering, or a path no workspace owns** — the site's
  own "I cannot answer": the git chip is empty (`fetchGitStateFor` returns the
  error and the compactor logs it), `set_git_worktree` returns a tool error
  naming the VM, `check-ignore` reports nothing ignored, `git_pr_status` /
  `git_pr_conflicts` answer `NotARepository`, and `status_pull_request` answers
  "no provider from origin". In no case does the host's git run.

## 5. What this does NOT do (stated, not implied)

* **`list_directory.zig:75` is not in this diff.** A cross-card dependency: the
  fs.write/fs.walk card (`task_1792319132618120369`) routes that tool into the
  guest, which removes the host call. It is still a host `git check-ignore` on
  the branch this PR targets.
* **§2.1's rule is broader than Appendix C, and this closes Appendix C.** These
  files still spawn host `git` with a request-supplied `path` as `-C`/cwd, none
  of them routed here:

  | file | host `git` argv literals |
  |---|---|
  | `http_handlers/git_commits.zig` | 11 |
  | `http_handlers/git_worktree_info.zig` | 6 |
  | `http_handlers/git_pr_diff.zig` | 6 |
  | `http_handlers/git_commit.zig` | 5 |
  | `http_handlers/git_changes.zig`, `http_handlers/git_file_stage.zig`, `http_handlers/git_pr_create.zig` | 4 each |
  | `http_handlers/git_file_diffs.zig`, `http_handlers/git_branches_list.zig`, `http_handlers/git_status.zig`, `http_handlers/tasks_list.zig`, `http_handlers/tasks_get.zig`, `http_handlers/session_list.zig` | 3, 3, 3, 2, 2, 2 |
  | `http_handlers/git_blame.zig`, `http_handlers/git_pr_checks.zig`, `http_handlers/git_pr_list.zig` | 2, 1, 2 |

  `git_pr_diff.zig` is the sharpest of them: a host `git diff` is the
  `.gitattributes` `textconv`/`filter.*` route, and `git_pr_diff.zig:167` also
  runs `git fetch` on the host. `git_file_stage.zig` and `git_commit.zig` are
  worse than reads — they *write* to the host tree. The `Route` seam built here
  is what those need; they were not in this card's scope and each has its own
  error semantics and tests.
* **Every host `gh`/`glab` invocation is untouched** — `pr_cli.zig` plus the
  `git_pr_*` handlers and both PR tools spawn the forge CLI with `cwd = path`.
  Criterion 9 names `gh` as well as `git`; routing the forge CLIs needs `gh` in
  the sealed guest image, which it does not have (the image ships git and no
  ripgrep — adding either is a manifest re-pin, §23).
* **`system_folder.zig`'s directory read is still a host read** (and so is its
  `git init` at line ~669, on a *fresh* workspace directory). Only the
  `check-ignore` call moved. In `--saas` the listing therefore shows the host's
  view of a path — criterion 8 territory, not this card's.
* **`classifyPath`'s disk probes are still host reads**: it decides
  `registered`/`orphaned`/`plain_directory` from `access`/`readFileAlloc` on the
  host, and only its `git worktree list` moved into the guest. In `--saas` the
  tenant tree usually is not on the host at all, so the precheck answers
  `not_found` and `git worktree add` produces the real error — but that is a
  coincidence of the sealed layout, not a design.
* **No live-VM run of the guest git path.** Every test here is L1 (pure, no VM);
  the exec RPC's git half has not been driven against a real guest by CI. The
  image ships `/usr/bin/git` (`policy.guest_git`), which is asserted by the
  image manifest, not by this change.

## 6. Verification

```
zig build test -Dtest-shards=1 -Dno-webapp-rebuild   → 4562 passed; 4 skipped; 0 failed
./zig-out/bin/zginlint src build.zig                 → 0 findings
```

Thirteen new tests, every one of them L1 (pure, no VM):

| test | what it pins |
|---|---|
| `git_state` ×3 | the fsmonitor canary (below) |
| `set_git_worktree` ×1 | the post-checkout hook canary (below) |
| `git_pr_status` ×1 | `--saas` answers `NotARepository` for a real repository |
| `git_pr_conflicts` ×1 | the same, through `useCase` |
| `status_pull_request` ×1 | a guest answers the provider question; the host's git is never the fallback |
| `system_folder` ×1 | `check-ignore` reports nothing ignored instead of asking the host |
| `workspace_fs` ×5 | `guestAbs`, the outside-path refusal, and `forPath` in local / saas / no-manager states |
| `workspace_scope` ×1 | `resolveWorkspaceForPath` finds an owner with no session |

**The two canaries, and what they actually prove.** Criterion 9 asks for a
fixture repo carrying a `core.fsmonitor` canary, and `set_git_worktree` can be
attacked the same way with a `post-checkout` hook. Both tests build one, and both
prove the canary is LIVE with a **plain** `git` invocation — the one thing the
hardening's `-c core.fsmonitor=false` / `core.hooksPath=/dev/null` deliberately
stops. That split is the honest result and it is worth stating plainly: in **local**
mode what protects the host is `git_hardening.zig`, not this seam, and the tests
assert exactly that (the hardened local run leaves the sentinel absent, a plain
run creates it). Under `--saas` the sentinel stays absent because **no host git
process exists at all** — that half is what criterion 9 is about.

The two control legs are POSIX-only: a `host_fixture` program is a `.cmd` on
Windows, and Git for Windows does not run a `.cmd` as a hook. The absence
assertions run everywhere.

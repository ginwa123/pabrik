// PARALLEL — MANDATORY Parallel Work Rules (CONSOLIDATED - Single Source of Truth)

pub const ParallelWork =
    \\## Parallel Work
    \\
    \\**Rule:** If 2+ tasks share zero dependencies AND each is substantial enough to be worth the coordination overhead, spawn sub-agents. Trivial tasks (a two-line config read, a one-word lookup) → do inline.
    \\
    \\```
    \\independent + substantial tasks → parallelize
    \\independent + trivial tasks     → do inline, don't spawn
    \\dependent tasks                 → sequential
    \\```
    \\
    \\### Spawn Sub-Agents For
    \\
    \\| Scenario                  | Strategy                         |
    \\|---------------------------|----------------------------------|
    \\| Read N files              | N agents, 1 per file              |
    \\| Research N topics         | N agents, 1 per topic             |
    \\| Search N patterns/symbols | N agents, 1 per pattern           |
    \\| Investigate N components  | N agents, 1 per component         |
    \\| Debug N independent bugs  | N agents, 1 per bug               |
    \\| Fetch N URLs              | N agents, 1 per URL               |
    \\| Run N independent tests   | N agents, 1 per test suite        |
    \\
    \\### Fan-out ceiling
    \\
    \\Above ~8 concurrent tasks, batch them (e.g. 8 at a time) rather than firing all N simultaneously — keeps synthesis manageable.
    \\
    \\### Fan-in: sub-agents return findings, not raw output
    \\
    \\**This is the part that's easy to get wrong.** A sub-agent reading a file should NOT dump the full file content back to the parent — that just moves the bloat from serial to parallel.
    \\
    \\- Sub-agent: do the work, return a short distilled summary of what matters for the parent's task (the answer, the relevant excerpt, the finding) — not the full transcript of how it got there.
    \\- Parent: synthesize N short summaries, not N full outputs.
    \\- If the parent genuinely needs raw content later (e.g. to edit the file), it re-reads it directly at that point.
    \\
    \\### Never Spawn For
    \\
    \\- Edits touching the **same file** or **same shared mutable state** (race conditions, corrupted writes) — independent files are fine to parallelize.
    \\- Any task where step B needs output from step A.
    \\- Single-file edits or single-target operations.
    \\- Build/test pipelines with ordered stages.
    \\
    \\### Mixed dependency graphs
    \\
    \\Most real tasks aren't purely parallel or sequential. Break the work into stages at each sync point:
    \\
    \\```
    \\spawn(read(a.ts), read(b.ts), read(c.ts))   // stage 1: parallel
    \\→ synthesize findings
    \\edit(shared-config.ts)                       // stage 2: sequential
    \\→ spawn(test(a), test(b), test(c))           // stage 3: parallel
    \\```
    \\
    \\Identify sync points, then parallelize freely within each stage.
    \\
    \\### Decision Test
    \\
    \\Before starting, ask: "Can task B begin before task A finishes?" Yes → parallel; No → sequential. And: "Is spawning substantial enough to beat doing it inline?" If not, do it directly.
    \\
    \\### Handling partial failures
    \\
    \\- Retry only the failed agents, not the whole batch.
    \\- Critical-path task failed → don't proceed on partial results; surface the gap.
    \\- Non-critical miss (e.g. 1 of 10 research topics empty) → proceed with what succeeded and note the gap.
    \\
    \\### Examples
    \\
    \\**Wrong:** `read(auth.ts); read(router.ts); read(db.ts);` — slow, wasteful serial reads.
    \\**Right:** `spawn(read(auth.ts), read(router.ts), read(db.ts));` — each returns a distilled summary ("auth.ts: uses JWT, no refresh token logic"), not full file content.
    \\
    \\**Wrong:** `spawn(edit(auth.ts), edit(auth.ts));` — parallel write to the same file corrupts it.
    \\**Right:** `edit(auth.ts); edit(auth.ts);` for same-file edits (ordered); `spawn(edit(auth.ts), edit(billing.ts));` for independent files.
;

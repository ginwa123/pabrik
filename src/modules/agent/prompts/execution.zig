// EXECUTION — Classification, execution, escalation

pub const Classification =
    \\## Classification
    \\| Type | Action |
    \\|---|---|
    \\| Simple | Execute directly |
    \\| Moderate | 2-4 steps, spawn agents if needed |
    \\| Complex | Plan → "yes/proceed" → execute |
;

pub const Execution =
    \\## Execution
    \\
    \\**⚠️ SIMPLEST FIRST RULE:**
    \\- Always choose the **simplest approach** that solves the problem
    \\- Avoid over-engineering, premature optimization, unnecessary abstraction
    \\- One-line fix works → don't write a function; patch works → don't refactor
    \\- Only add complexity with clear evidence it's needed
    \\
    \\**⚠️ SURGICAL CODE PATCHING (Enhancing Existing Code):**
    \\- **NEVER refactor** existing code when enhancing it
    \\- Minimal targeted changes only, via `text_replace`
    \\- Change only what's necessary; leave surrounding code untouched unless directly affected
    \\
    \\**⚠️ VERIFICATION WORKFLOW:**
    \\1. Write test → run test → FAIL ❌
    \\2. Write impl  → run test → PASS ✅
    \\3. Build       → verify compilation ✅
    \\4. Read-back   → confirm edits landed
    \\5. Report with evidence
    \\
    \\**❌ WRONG:** "Let me refactor this to make it cleaner"
    \\**✅ RIGHT:** "Let me surgically patch this specific issue"
;

pub const Escalation =
    \\## Escalation
    \\1. Try different strategy
    \\2. Same error twice → skill re-load
    \\3. Still stuck → document and escalate
;
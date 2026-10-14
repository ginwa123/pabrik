// =============================================================================
// PROMPTS — Unified prompt system
// =============================================================================
// Split by purpose:
//   - core:        Universal rules, response formatting, update-activity
//   - agent:       Main orchestration directive
//   - parallel:    MANDATORY parallel work rules
//   - memory:      AGENTS.md, tasks, git, PABRIK.md, skills system
//   - execution:   Classification, execution, escalation
//   - special:     CompactionAgent, GenerateSessionNameAgent
// =============================================================================

pub const core = @import("core.zig");
pub const agent = @import("agent.zig");
pub const parallel = @import("parallel.zig");
pub const execution = @import("execution.zig");
pub const memory = @import("memory.zig");
pub const special = @import("special.zig");

// Re-export for convenience
pub const UniversalRules = core.UniversalRules;
pub const PromptAutoFix = core.PromptAutoFix;
pub const ResponseFormatting = core.ResponseFormatting;
pub const SearchToolRule = core.SearchToolRule;
// Progressive tool search: `search_tool` is the agent's special tool — the
// mandate to search the catalog for the tool a task needs (search_tool ->
// view_tool -> use_tool). Gated on search_tool being in the resolved tool set.
// Skills: `search_skills` / `use_skill` are the agent's special skills — the
// mandate to load the skill a task needs. Gated on use_skill being present.
pub const ProgressiveToolRule = core.ProgressiveToolRule;
pub const SkillsToolRule = core.SkillsToolRule;
pub const SkillEvalToolRule = core.SkillEvalToolRule;
// The WRITE half of the loop: create a skill from what the task just taught,
// and edit one an eval flags. Same unconditional-append reasoning — the
// tools it names (`add_skill` / `edit_skill`) are always equipped, so gating
// on them would only fragment the cached prefix.
pub const SkillWriteToolRule = core.SkillWriteToolRule;
// Session VCS binding: a worktree and a pull request each have a tool that does
// the git/filesystem half AND writes the session's binding — the shell command
// only does the git half. Unconditional, like the mandates above, and each rule
// names its own `search_tool` → `use_tool` hatch because neither tool is in
// `DEFAULT_AGENT_TOOLS`.
pub const GitWorktreeToolRule = core.GitWorktreeToolRule;
pub const PullRequestToolRule = core.PullRequestToolRule;
pub const ReadWorkspaceSessionToolRule = core.ReadWorkspaceSessionToolRule;
// Workspace credentials: the `{{SECRETS:NAME}}` placeholder and the
// never-echo-the-value rule. Unlike the four unconditional rules above this
// one is GATED on `list_secrets` being in the resolved tool list, because
// the tool is injected rather than seeded (see `filterAndMergeTools`), so
// its presence is not constant across agents the way theirs is.
pub const SecretsToolRule = core.SecretsToolRule;
pub const MemoryToolRule = core.MemoryToolRule;
pub const CrossProjectCwdRule = core.CrossProjectCwdRule;

pub const Agent = agent.Agent;

pub const ParallelWork = parallel.ParallelWork;

pub const Classification = execution.Classification;
pub const Execution = execution.Execution;
pub const Escalation = execution.Escalation;

pub const MemoryPrompt = memory.MemoryPrompt;
pub const GitPrompt = memory.GitPrompt;
pub const PabrikMdAutoUpdate = memory.PabrikMdAutoUpdate;
pub const GlobalMemorySystem = memory.GlobalMemorySystem;
pub const LocalMemorySystem = memory.LocalMemorySystem;

pub const CompactionAgent = special.CompactionAgent;
pub const GenerateSessionNameAgent = special.GenerateSessionNameAgent;

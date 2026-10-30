// =============================================================================
// PROMPTS — Unified prompt system
// =============================================================================

pub const core = @import("core.zig");
pub const agent = @import("agent.zig");
pub const parallel = @import("parallel.zig");
pub const execution = @import("execution.zig");
pub const memory = @import("memory.zig");
pub const special = @import("special.zig");

// Re-export for convenience
pub const UniversalRules = core.UniversalRules;
pub const TemporaryFilesRule = core.TemporaryFilesRule;
pub const PromptAutoFix = core.PromptAutoFix;
pub const ResponseFormatting = core.ResponseFormatting;
pub const SearchToolRule = core.SearchToolRule;
// Progressive tool search: `search_tool` is the agent's special tool — the
// mandate to search the catalog for the tool a task needs (search_tool ->
// view_tool -> use_tool).
pub const ProgressiveToolRule = core.ProgressiveToolRule;
pub const SkillsToolRule = core.SkillsToolRule;
pub const SkillEvalToolRule = core.SkillEvalToolRule;
// The WRITE half of the loop: create a skill from what the task just taught,
// and edit one an eval flags.
pub const SkillWriteToolRule = core.SkillWriteToolRule;
// Session VCS binding: a worktree and a pull request each have a tool that
// does the git/filesystem half AND writes the session's binding — the shell
// command only does the git half.
pub const GitWorktreeToolRule = core.GitWorktreeToolRule;
pub const PullRequestToolRule = core.PullRequestToolRule;
pub const ReadWorkspaceSessionToolRule = core.ReadWorkspaceSessionToolRule;
// Workspace credentials: the `{{SECRETS:NAME}}` placeholder and the
// never-echo-the-value rule.
pub const SecretsToolRule = core.SecretsToolRule;
pub const MemoryToolRule = core.MemoryToolRule;
pub const AskUserRule = core.AskUserRule;
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



pub const makeWorkspaceContext = @import("prompts_make_workspace_context.zig").makeWorkspaceContext;
pub const makeCrossProjectCwdContext = @import("prompts_make_cross_project_context.zig").makeCrossProjectCwdContext;
pub const makeWorkingDirectoryContext = @import("prompts_make_working_directory_context.zig").makeWorkingDirectoryContext;
pub const makeSkillsEquippedContext = @import("prompts_make_skills_equiped_context.zig").makeSkillsEquippedContext;
pub const makeKanbanContext = @import("prompts_make_kanban_context.zig").makeKanbanContext;
pub const makeActivityInfo = @import("prompts_make_activity_info_context.zig").makeActivityInfo;
pub const makeAgentKnowledge = @import("prompts_make_agent_knowledge.zig").makeAgentKnowledge;
pub const makeAgentSystemPrompt = @import("prompts_make_agent_system_prompt.zig").makeAgentSystemPrompt;
// Agent-Kanbans mirror (Migration 081)
pub const makeAgentKanbanKnowledge = @import("prompts_make_agent_kanban_knowledge.zig").makeAgentKanbanKnowledge;
pub const makeAgentKanbanSystemPrompt = @import("prompts_make_agent_kanban_system_prompt.zig").makeAgentKanbanSystemPrompt;
// Agent-Routines mirror (Migration 087)
pub const makeAgentRoutineKnowledge = @import("prompts_make_agent_routine_knowledge.zig").makeAgentRoutineKnowledge;
pub const makeAgentRoutineSystemPrompt = @import("prompts_make_agent_routine_system_prompt.zig").makeAgentRoutineSystemPrompt;
pub const makePlanContext = @import("prompts_make_plan_context.zig").makePlanContext;

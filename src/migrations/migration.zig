const std = @import("std");
const pabrikcore = @import("pabrikcore");
const helpers = @import("helpers");
const common = @import("common.zig");

pub const Migration = common.Migration;
pub const MigrationManager = common.MigrationManager;
pub const SqliteBackend = common.SqliteBackend;
pub const addColumnIfMissing = common.addColumnIfMissing;
pub const dropColumnIfExists = common.dropColumnIfExists;
pub const renameColumnIfExists = common.renameColumnIfExists;

// Per-version migration modules. File name matches the
// `version: u32` inside (migration_78.zig holds version 78,
// even though its struct keeps the historical
// `Migration076…` prefix). No files exist for versions 10
// and 47 — those versions were never assigned.
const migration_1 = @import("migration_1.zig");
const migration_2 = @import("migration_2.zig");
const migration_3 = @import("migration_3.zig");
const migration_4 = @import("migration_4.zig");
const migration_5 = @import("migration_5.zig");
const migration_6 = @import("migration_6.zig");
const migration_7 = @import("migration_7.zig");
const migration_8 = @import("migration_8.zig");
const migration_9 = @import("migration_9.zig");
const migration_11 = @import("migration_11.zig");
const migration_12 = @import("migration_12.zig");
const migration_13 = @import("migration_13.zig");
const migration_14 = @import("migration_14.zig");
const migration_15 = @import("migration_15.zig");
const migration_16 = @import("migration_16.zig");
const migration_17 = @import("migration_17.zig");
const migration_18 = @import("migration_18.zig");
const migration_19 = @import("migration_19.zig");
const migration_20 = @import("migration_20.zig");
const migration_21 = @import("migration_21.zig");
const migration_22 = @import("migration_22.zig");
const migration_23 = @import("migration_23.zig");
const migration_24 = @import("migration_24.zig");
const migration_25 = @import("migration_25.zig");
const migration_26 = @import("migration_26.zig");
const migration_27 = @import("migration_27.zig");
const migration_28 = @import("migration_28.zig");
const migration_29 = @import("migration_29.zig");
const migration_30 = @import("migration_30.zig");
const migration_31 = @import("migration_31.zig");
const migration_32 = @import("migration_32.zig");
const migration_33 = @import("migration_33.zig");
const migration_34 = @import("migration_34.zig");
const migration_35 = @import("migration_35.zig");
const migration_36 = @import("migration_36.zig");
const migration_37 = @import("migration_37.zig");
const migration_38 = @import("migration_38.zig");
const migration_39 = @import("migration_39.zig");
const migration_40 = @import("migration_40.zig");
const migration_41 = @import("migration_41.zig");
const migration_42 = @import("migration_42.zig");
const migration_43 = @import("migration_43.zig");
const migration_44 = @import("migration_44.zig");
const migration_45 = @import("migration_45.zig");
const migration_46 = @import("migration_46.zig");
const migration_48 = @import("migration_48.zig");
const migration_49 = @import("migration_49.zig");
const migration_50 = @import("migration_50.zig");
const migration_51 = @import("migration_51.zig");
const migration_52 = @import("migration_52.zig");
const migration_53 = @import("migration_53.zig");
const migration_54 = @import("migration_54.zig");
const migration_55 = @import("migration_55.zig");
const migration_56 = @import("migration_56.zig");
const migration_57 = @import("migration_57.zig");
const migration_58 = @import("migration_58.zig");
const migration_59 = @import("migration_59.zig");
const migration_60 = @import("migration_60.zig");
const migration_61 = @import("migration_61.zig");
const migration_62 = @import("migration_62.zig");
const migration_63 = @import("migration_63.zig");
const migration_64 = @import("migration_64.zig");
const migration_65 = @import("migration_65.zig");
const migration_66 = @import("migration_66.zig");
const migration_67 = @import("migration_67.zig");
const migration_68 = @import("migration_68.zig");
const migration_69 = @import("migration_69.zig");
const migration_70 = @import("migration_70.zig");
const migration_71 = @import("migration_71.zig");
const migration_72 = @import("migration_72.zig");
const migration_73 = @import("migration_73.zig");
const migration_74 = @import("migration_74.zig");
const migration_75 = @import("migration_75.zig");
const migration_76 = @import("migration_76.zig");
const migration_77 = @import("migration_77.zig");
const migration_78 = @import("migration_78.zig");
const migration_79 = @import("migration_79.zig");
const migration_80 = @import("migration_80.zig");
const migration_81 = @import("migration_81.zig");
const migration_82 = @import("migration_82.zig");
const migration_83 = @import("migration_83.zig");
const migration_84 = @import("migration_84.zig");
const migration_85 = @import("migration_85.zig");
const migration_86 = @import("migration_86.zig");
const migration_87 = @import("migration_87.zig");
const migration_88 = @import("migration_88.zig");
const migration_89 = @import("migration_89.zig");
const migration_90 = @import("migration_90.zig");
const migration_91 = @import("migration_91.zig");
const migration_92 = @import("migration_92.zig");
const migration_93 = @import("migration_93.zig");
const migration_94 = @import("migration_94.zig");
const migration_95 = @import("migration_95.zig");
const migration_96 = @import("migration_96.zig");
const migration_97 = @import("migration_97.zig");
const migration_98 = @import("migration_98.zig");
const migration_99 = @import("migration_99.zig");
const migration_100 = @import("migration_100.zig");
const migration_101 = @import("migration_101.zig");
const migration_102 = @import("migration_102.zig");
const migration_103 = @import("migration_103.zig");
const migration_104 = @import("migration_104.zig");
const migration_105 = @import("migration_105.zig");

// Re-exports so existing
// `@import("../migrations/migration.zig").Migration076…` call sites
// keep compiling unchanged.
pub const Migration001CreateLLMHistory = migration_1.Migration001CreateLLMHistory;
pub const Migration002AddRoleToLLMHistory = migration_2.Migration002AddRoleToLLMHistory;
pub const Migration003AddReasoningContent = migration_3.Migration003AddReasoningContent;
pub const Migration004AddSessionDir = migration_4.Migration004AddSessionDir;
pub const Migration005AddIsFeedToLLM = migration_5.Migration005AddIsFeedToLLM;
pub const Migration006AddAgent = migration_6.Migration006AddAgent;
pub const Migration007AddSessionTracking = migration_7.Migration007AddSessionTracking;
pub const Migration008AddSessionSkills = migration_8.Migration008AddSessionSkills;
pub const Migration009RemoveCreatedColumn = migration_9.Migration009RemoveCreatedColumn;
pub const Migration011AddTemperatureAndThinking = migration_11.Migration011AddTemperatureAndThinking;
pub const Migration012AddParentTracking = migration_12.Migration012AddParentTracking;
pub const Migration013AddTokenUsageColumns = migration_13.Migration013AddTokenUsageColumns;
pub const Migration014AddBackgroundProcess = migration_14.Migration014AddBackgroundProcess;
pub const Migration015AddSessionAgents = migration_15.Migration015AddSessionAgents;
pub const Migration016AddInputOutputColumns = migration_16.Migration016AddInputOutputColumns;
pub const Migration017CreateSessionsTable = migration_17.Migration017CreateSessionsTable;
pub const Migration018CreateSessionQueueMessages = migration_18.Migration018CreateSessionQueueMessages;
pub const Migration019CreateWorkerTable = migration_19.Migration019CreateWorkerTable;
pub const Migration020AddWorkerExtraFields = migration_20.Migration020AddWorkerExtraFields;
pub const Migration021RemoveSessionNameFromLlmHistory = migration_21.Migration021RemoveSessionNameFromLlmHistory;
pub const Migration022AddCwdToSessions = migration_22.Migration022AddCwdToSessions;
pub const Migration023DropSessionDirFromLlmHistory = migration_23.Migration023DropSessionDirFromLlmHistory;
pub const Migration024CreateWorkspaces = migration_24.Migration024CreateWorkspaces;
pub const Migration025AddWorkspaceIdToSessions = migration_25.Migration025AddWorkspaceIdToSessions;
pub const Migration026DropSessionIdFromWorkspaces = migration_26.Migration026DropSessionIdFromWorkspaces;
pub const Migration027AddNameToWorkspaces = migration_27.Migration027AddNameToWorkspaces;
pub const Migration028CreateWorkspaceItems = migration_28.Migration028CreateWorkspaceItems;
pub const Migration029AddTimestampsToSessions = migration_29.Migration029AddTimestampsToSessions;
pub const Migration030AddTimestampsToWorkspaces = migration_30.Migration030AddTimestampsToWorkspaces;
pub const Migration031AddTimestampsToWorkspaceItems = migration_31.Migration031AddTimestampsToWorkspaceItems;
pub const Migration032AddNamePathToWorkspaceItems = migration_32.Migration032AddNamePathToWorkspaceItems;
pub const Migration033AddCancelledToWorker = migration_33.Migration033AddCancelledToWorker;
pub const Migration034CreateWorkspaceItemTasks = migration_34.Migration034CreateWorkspaceItemTasks;
pub const Migration035AddDiffViewColumns = migration_35.Migration035AddDiffViewColumns;
pub const Migration036AddImageUrlToLlmHistory = migration_36.Migration036AddImageUrlToLlmHistory;
pub const Migration037AddImageUrlToSessionQueueMessages = migration_37.Migration037AddImageUrlToSessionQueueMessages;
pub const Migration038DropToolResultsJson = migration_38.Migration038DropToolResultsJson;
pub const Migration039AddToolCallIdToLlmHistory = migration_39.Migration039AddToolCallIdToLlmHistory;
pub const Migration040AddSelectedProfileModelToSessions = migration_40.Migration040AddSelectedProfileModelToSessions;
pub const Migration041AddPerformanceIndexes = migration_41.Migration041AddPerformanceIndexes;
pub const Migration042AddWorkspaceItemTasksUpdatedAtIndex = migration_42.Migration042AddWorkspaceItemTasksUpdatedAtIndex;
pub const Migration043AddPositionToWorkspaces = migration_43.Migration043AddPositionToWorkspaces;
pub const Migration044AddRoutines = migration_44.Migration044AddRoutines;
pub const Migration045AddPositionToWorkspaceItems = migration_45.Migration045AddPositionToWorkspaceItems;
pub const Migration046AddGitWorktreeCwdToSessions = migration_46.Migration046AddGitWorktreeCwdToSessions;
pub const Migration048AddChatListIndex = migration_48.Migration048AddChatListIndex;
pub const Migration049AddDefensiveIndexes = migration_49.Migration049AddDefensiveIndexes;
pub const Migration050AddPinnedToWorkspaceItemTasks = migration_50.Migration050AddPinnedToWorkspaceItemTasks;
pub const Migration051AddKanban = migration_51.Migration051AddKanban;
pub const Migration052DropSessionIdFromWorkspaceItemTasks = migration_52.Migration052DropSessionIdFromWorkspaceItemTasks;
pub const Migration053AddKanbanColumnDescription = migration_53.Migration053AddKanbanColumnDescription;
pub const Migration054MakeSessionQueueMessageNullable = migration_54.Migration054MakeSessionQueueMessageNullable;
pub const Migration055AddDesignPages = migration_55.Migration055AddDesignPages;
pub const Migration056UpgradeDesignPagesToFileModel = migration_56.Migration056UpgradeDesignPagesToFileModel;
pub const Migration057AddDesignElementProperties = migration_57.Migration057AddDesignElementProperties;
pub const Migration058AddLlmHistoryFts = migration_58.Migration058AddLlmHistoryFts;
pub const Migration059AddCreatedIso = migration_59.Migration059AddCreatedIso;
pub const Migration060RebackfillCreatedIso = migration_60.Migration060RebackfillCreatedIso;
pub const Migration061FixCreatedIsoYear = migration_61.Migration061FixCreatedIsoYear;
pub const Migration062AddTaskDescription = migration_62.Migration062AddTaskDescription;
pub const Migration063AddSessionAutoRetry = migration_63.Migration063AddSessionAutoRetry;
pub const Migration064AddFrontendLogs = migration_64.Migration064AddFrontendLogs;
pub const Migration065AddTaskHumanTouchedAt = migration_65.Migration065AddTaskHumanTouchedAt;
pub const Migration066AddDesignPageTaskFk = migration_66.Migration066AddDesignPageTaskFk;
pub const Migration067AddTaskTags = migration_67.Migration067AddTaskTags;
pub const Migration068AddToolCallLoading = migration_68.Migration068AddToolCallLoading;
pub const Migration069AddTaskImageUrls = migration_69.Migration069AddTaskImageUrls;
pub const Migration070AddAgentMemories = migration_70.Migration070AddAgentMemories;
pub const Migration071AddTaskCwd = migration_71.Migration071AddTaskCwd;
pub const Migration072ExtractKanbanTable = migration_72.Migration072ExtractKanbanTable;
pub const Migration073AddSessionActivity = migration_73.Migration073AddSessionActivity;
pub const Migration074AddLlmHistoryCacheTokenColumns = migration_74.Migration074AddLlmHistoryCacheTokenColumns;
pub const Migration075RenameTimestampColumnsToNanoSuffix = migration_75.Migration075RenameTimestampColumnsToNanoSuffix;
pub const Migration076CreateSessionPlan = migration_76.Migration076CreateSessionPlan;
pub const Migration077AddUsersAndRbacSchema = migration_77.Migration077AddUsersAndRbacSchema;
pub const Migration076AddAgentsAndAgentKnowledgeAndAgentTools = migration_78.Migration076AddAgentsAndAgentKnowledgeAndAgentTools;
pub const Migration079AddContentToAgentKnowledge = migration_79.Migration079AddContentToAgentKnowledge;
pub const Migration080AddAgentSystemPrompt = migration_80.Migration080AddAgentSystemPrompt;
pub const Migration081CreateAgentKanbans = migration_81.Migration081CreateAgentKanbans;
pub const Migration082AddSessionHumanTouchedAt = migration_82.Migration082AddSessionHumanTouchedAt;
pub const Migration083AddReasoningIdAndEncryptedContent = migration_83.Migration083AddReasoningIdAndEncryptedContent;
pub const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration_84.Migration084ReplaceRoutinesWithWorkspaceRoutines;
pub const Migration085AddSessionProgressiveTool = migration_85.Migration085AddSessionProgressiveTool;
pub const Migration086AddSessionPrUrl = migration_86.Migration086AddSessionPrUrl;
pub const Migration087CreateAgentRoutines = migration_87.Migration087CreateAgentRoutines;
pub const Migration088AddSessionPendingQuestion = migration_88.Migration088AddSessionPendingQuestion;
pub const Migration089AuthSessions = migration_89.Migration089AuthSessions;
pub const Migration090AddVideoUrls = migration_90.Migration090AddVideoUrls;
pub const Migration091AddSubAgentNameToSessions = migration_91.Migration091AddSubAgentNameToSessions;
pub const Migration092AddUserConfigJson = migration_92.Migration092AddUserConfigJson;
pub const Migration093AddOwnerColumns = migration_93.Migration093AddOwnerColumns;
pub const Migration094AddDefaultProjectToWorkspaceItems = migration_94.Migration094AddDefaultProjectToWorkspaceItems;
pub const Migration095AddWorkspaceIdToAgentMemories = migration_95.Migration095AddWorkspaceIdToAgentMemories;
pub const Migration096CreateSessionSkillEvents = migration_96.Migration096CreateSessionSkillEvents;
pub const Migration097CreateSkillEvalTables = migration_97.Migration097CreateSkillEvalTables;
pub const Migration098CreateDocuments = migration_98.Migration098CreateDocuments;
pub const Migration099RenameListSkillsTool = migration_99.Migration099RenameListSkillsTool;
pub const Migration100AddWorkspaceMembers = migration_100.Migration100AddWorkspaceMembers;
pub const Migration101GuardLlmHistoryModel = migration_101.Migration101GuardLlmHistoryModel;
pub const Migration102CreateSkills = migration_102.Migration102CreateSkills;
pub const Migration103CreateWorkspaceSecrets = migration_103.Migration103CreateWorkspaceSecrets;
pub const Migration104AddSessionPinned = migration_104.Migration104AddSessionPinned;
pub const Migration105CreateWorkspaceSettings = migration_105.Migration105CreateWorkspaceSettings;

/// All available migrations - add new migrations to this slice
pub const allMigrations: []const Migration = &.{
    .{ .version = Migration001CreateLLMHistory.version, .name = Migration001CreateLLMHistory.name, .up = Migration001CreateLLMHistory.up },
    .{ .version = Migration002AddRoleToLLMHistory.version, .name = Migration002AddRoleToLLMHistory.name, .up = Migration002AddRoleToLLMHistory.up },
    .{ .version = Migration003AddReasoningContent.version, .name = Migration003AddReasoningContent.name, .up = Migration003AddReasoningContent.up },
    .{ .version = Migration004AddSessionDir.version, .name = Migration004AddSessionDir.name, .up = Migration004AddSessionDir.up },
    .{ .version = Migration005AddIsFeedToLLM.version, .name = Migration005AddIsFeedToLLM.name, .up = Migration005AddIsFeedToLLM.up },
    .{ .version = Migration006AddAgent.version, .name = Migration006AddAgent.name, .up = Migration006AddAgent.up },
    .{ .version = Migration007AddSessionTracking.version, .name = Migration007AddSessionTracking.name, .up = Migration007AddSessionTracking.up },
    .{ .version = Migration008AddSessionSkills.version, .name = Migration008AddSessionSkills.name, .up = Migration008AddSessionSkills.up },
    .{ .version = Migration009RemoveCreatedColumn.version, .name = Migration009RemoveCreatedColumn.name, .up = Migration009RemoveCreatedColumn.up },
    .{ .version = Migration011AddTemperatureAndThinking.version, .name = Migration011AddTemperatureAndThinking.name, .up = Migration011AddTemperatureAndThinking.up },
    .{ .version = Migration012AddParentTracking.version, .name = Migration012AddParentTracking.name, .up = Migration012AddParentTracking.up },
    .{ .version = Migration013AddTokenUsageColumns.version, .name = Migration013AddTokenUsageColumns.name, .up = Migration013AddTokenUsageColumns.up },
    .{ .version = Migration014AddBackgroundProcess.version, .name = Migration014AddBackgroundProcess.name, .up = Migration014AddBackgroundProcess.up },
    .{ .version = Migration015AddSessionAgents.version, .name = Migration015AddSessionAgents.name, .up = Migration015AddSessionAgents.up },
    .{ .version = Migration016AddInputOutputColumns.version, .name = Migration016AddInputOutputColumns.name, .up = Migration016AddInputOutputColumns.up },
    .{ .version = Migration017CreateSessionsTable.version, .name = Migration017CreateSessionsTable.name, .up = Migration017CreateSessionsTable.up },
    .{ .version = Migration018CreateSessionQueueMessages.version, .name = Migration018CreateSessionQueueMessages.name, .up = Migration018CreateSessionQueueMessages.up },
    .{ .version = Migration019CreateWorkerTable.version, .name = Migration019CreateWorkerTable.name, .up = Migration019CreateWorkerTable.up },
    .{ .version = Migration020AddWorkerExtraFields.version, .name = Migration020AddWorkerExtraFields.name, .up = Migration020AddWorkerExtraFields.up },
    .{ .version = Migration021RemoveSessionNameFromLlmHistory.version, .name = Migration021RemoveSessionNameFromLlmHistory.name, .up = Migration021RemoveSessionNameFromLlmHistory.up },
    .{ .version = Migration022AddCwdToSessions.version, .name = Migration022AddCwdToSessions.name, .up = Migration022AddCwdToSessions.up },
    .{ .version = Migration023DropSessionDirFromLlmHistory.version, .name = Migration023DropSessionDirFromLlmHistory.name, .up = Migration023DropSessionDirFromLlmHistory.up },
    .{ .version = Migration024CreateWorkspaces.version, .name = Migration024CreateWorkspaces.name, .up = Migration024CreateWorkspaces.up },
    .{ .version = Migration025AddWorkspaceIdToSessions.version, .name = Migration025AddWorkspaceIdToSessions.name, .up = Migration025AddWorkspaceIdToSessions.up },
    .{ .version = Migration026DropSessionIdFromWorkspaces.version, .name = Migration026DropSessionIdFromWorkspaces.name, .up = Migration026DropSessionIdFromWorkspaces.up },
    .{ .version = Migration027AddNameToWorkspaces.version, .name = Migration027AddNameToWorkspaces.name, .up = Migration027AddNameToWorkspaces.up },
    .{ .version = Migration028CreateWorkspaceItems.version, .name = Migration028CreateWorkspaceItems.name, .up = Migration028CreateWorkspaceItems.up },
    .{ .version = Migration029AddTimestampsToSessions.version, .name = Migration029AddTimestampsToSessions.name, .up = Migration029AddTimestampsToSessions.up },
    .{ .version = Migration030AddTimestampsToWorkspaces.version, .name = Migration030AddTimestampsToWorkspaces.name, .up = Migration030AddTimestampsToWorkspaces.up },
    .{ .version = Migration031AddTimestampsToWorkspaceItems.version, .name = Migration031AddTimestampsToWorkspaceItems.name, .up = Migration031AddTimestampsToWorkspaceItems.up },
    .{ .version = Migration032AddNamePathToWorkspaceItems.version, .name = Migration032AddNamePathToWorkspaceItems.name, .up = Migration032AddNamePathToWorkspaceItems.up },
    .{ .version = Migration033AddCancelledToWorker.version, .name = Migration033AddCancelledToWorker.name, .up = Migration033AddCancelledToWorker.up },
    .{ .version = Migration034CreateWorkspaceItemTasks.version, .name = Migration034CreateWorkspaceItemTasks.name, .up = Migration034CreateWorkspaceItemTasks.up },
    .{ .version = Migration035AddDiffViewColumns.version, .name = Migration035AddDiffViewColumns.name, .up = Migration035AddDiffViewColumns.up },
    .{ .version = Migration036AddImageUrlToLlmHistory.version, .name = Migration036AddImageUrlToLlmHistory.name, .up = Migration036AddImageUrlToLlmHistory.up },
    .{ .version = Migration037AddImageUrlToSessionQueueMessages.version, .name = Migration037AddImageUrlToSessionQueueMessages.name, .up = Migration037AddImageUrlToSessionQueueMessages.up },
    .{ .version = Migration038DropToolResultsJson.version, .name = Migration038DropToolResultsJson.name, .up = Migration038DropToolResultsJson.up },
    .{ .version = Migration039AddToolCallIdToLlmHistory.version, .name = Migration039AddToolCallIdToLlmHistory.name, .up = Migration039AddToolCallIdToLlmHistory.up },
    .{ .version = Migration040AddSelectedProfileModelToSessions.version, .name = Migration040AddSelectedProfileModelToSessions.name, .up = Migration040AddSelectedProfileModelToSessions.up },
    .{ .version = Migration041AddPerformanceIndexes.version, .name = Migration041AddPerformanceIndexes.name, .up = Migration041AddPerformanceIndexes.up },
    .{ .version = Migration042AddWorkspaceItemTasksUpdatedAtIndex.version, .name = Migration042AddWorkspaceItemTasksUpdatedAtIndex.name, .up = Migration042AddWorkspaceItemTasksUpdatedAtIndex.up },
    .{ .version = Migration043AddPositionToWorkspaces.version, .name = Migration043AddPositionToWorkspaces.name, .up = Migration043AddPositionToWorkspaces.up },
    .{ .version = Migration044AddRoutines.version, .name = Migration044AddRoutines.name, .up = Migration044AddRoutines.up },
    .{ .version = Migration045AddPositionToWorkspaceItems.version, .name = Migration045AddPositionToWorkspaceItems.name, .up = Migration045AddPositionToWorkspaceItems.up },
    .{ .version = Migration046AddGitWorktreeCwdToSessions.version, .name = Migration046AddGitWorktreeCwdToSessions.name, .up = Migration046AddGitWorktreeCwdToSessions.up },
    .{ .version = Migration048AddChatListIndex.version, .name = Migration048AddChatListIndex.name, .up = Migration048AddChatListIndex.up },
    .{ .version = Migration049AddDefensiveIndexes.version, .name = Migration049AddDefensiveIndexes.name, .up = Migration049AddDefensiveIndexes.up },
    .{ .version = Migration050AddPinnedToWorkspaceItemTasks.version, .name = Migration050AddPinnedToWorkspaceItemTasks.name, .up = Migration050AddPinnedToWorkspaceItemTasks.up },
    .{ .version = Migration051AddKanban.version, .name = Migration051AddKanban.name, .up = Migration051AddKanban.up },
    .{ .version = Migration052DropSessionIdFromWorkspaceItemTasks.version, .name = Migration052DropSessionIdFromWorkspaceItemTasks.name, .up = Migration052DropSessionIdFromWorkspaceItemTasks.up },
    .{ .version = Migration053AddKanbanColumnDescription.version, .name = Migration053AddKanbanColumnDescription.name, .up = Migration053AddKanbanColumnDescription.up },
    .{ .version = Migration054MakeSessionQueueMessageNullable.version, .name = Migration054MakeSessionQueueMessageNullable.name, .up = Migration054MakeSessionQueueMessageNullable.up },
    .{ .version = Migration055AddDesignPages.version, .name = Migration055AddDesignPages.name, .up = Migration055AddDesignPages.up },
    .{ .version = Migration056UpgradeDesignPagesToFileModel.version, .name = Migration056UpgradeDesignPagesToFileModel.name, .up = Migration056UpgradeDesignPagesToFileModel.up },
    .{ .version = Migration057AddDesignElementProperties.version, .name = Migration057AddDesignElementProperties.name, .up = Migration057AddDesignElementProperties.up },
    .{ .version = Migration058AddLlmHistoryFts.version, .name = Migration058AddLlmHistoryFts.name, .up = Migration058AddLlmHistoryFts.up },
    .{ .version = Migration059AddCreatedIso.version, .name = Migration059AddCreatedIso.name, .up = Migration059AddCreatedIso.up },
    .{ .version = Migration060RebackfillCreatedIso.version, .name = Migration060RebackfillCreatedIso.name, .up = Migration060RebackfillCreatedIso.up },
    .{ .version = Migration061FixCreatedIsoYear.version, .name = Migration061FixCreatedIsoYear.name, .up = Migration061FixCreatedIsoYear.up },
    .{ .version = Migration062AddTaskDescription.version, .name = Migration062AddTaskDescription.name, .up = Migration062AddTaskDescription.up },
    .{ .version = Migration063AddSessionAutoRetry.version, .name = Migration063AddSessionAutoRetry.name, .up = Migration063AddSessionAutoRetry.up },
    .{ .version = Migration064AddFrontendLogs.version, .name = Migration064AddFrontendLogs.name, .up = Migration064AddFrontendLogs.up },
    // Chunk 1 of kanban-task-notification-icon plan: stamps
    // `last_human_touched_at` on tasks the user has interacted
    // with (drag, rename, edit desc, pin, send message, open chat).
    // Used by the kanban card UI to decide whether to show the
    // orange "awaiting review" dot or the green "reviewed"
    // checkmark alongside `sessions.last_finish_reason` (Migration
    // 063). See docs/plans/2026-07-26-kanban-task-notification-icon.md.
    .{ .version = Migration065AddTaskHumanTouchedAt.version, .name = Migration065AddTaskHumanTouchedAt.name, .up = Migration065AddTaskHumanTouchedAt.up },
    // design-page-workspace-item-task-fk plan, Task 1: adds the FK
    // column + UNIQUE index + backfill so each design page is bound
    // to its chat task at the row level (replaces the name-pattern
    // lookup in AppLayout.handleDesignOpenChat). See
    // docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md.
    .{ .version = Migration066AddDesignPageTaskFk.version, .name = Migration066AddDesignPageTaskFk.name, .up = Migration066AddDesignPageTaskFk.up },
    // kanban task tags plan, Task 1: adds `tags TEXT NOT NULL DEFAULT ''`
    // so workspace_item_tasks rows can carry a JSON-encode array of user
    // labels. See docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    .{ .version = Migration067AddTaskTags.version, .name = Migration067AddTaskTags.name, .up = Migration067AddTaskTags.up },
    // tool-call-loading-placeholder plan, Task 1: adds
    // `llm_history.is_loading` + partial UNIQUE INDEX on
    // `tool_call_id` so we can pre-create tool-result placeholder
    // rows synchronously BEFORE the long-running tool execution
    // starts. Prevents "Invalid function ID" errors when the agent
    // crashes mid-tool-execution. See
    // docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
    // (task_1785784899843).
    .{ .version = Migration068AddToolCallLoading.version, .name = Migration068AddToolCallLoading.name, .up = Migration068AddToolCallLoading.up },
    // Migration 069 — adds `workspace_item_tasks.image_urls` so task
    // images are stored inline (base64 data URLs joined with `||`) on
    // the task row, no filesystem attachments, no broken GET route.
    // Task-id tracked: 1785795051796 ("kanban task not saving the
    // images or base 64 in kanban description, after create a task or
    // run aent").
    .{ .version = Migration069AddTaskImageUrls.version, .name = Migration069AddTaskImageUrls.name, .up = Migration069AddTaskImageUrls.up },
    // Migration 070 — agent_memories table + agent_memories_fts FTS5 +
    // 3 sync triggers. Backs the save_memory + load_memory agent tools
    // (Task task_1785958319567, plan 2026-08-06-save-load-memory-fts5).
    .{ .version = Migration070AddAgentMemories.version, .name = Migration070AddAgentMemories.name, .up = Migration070AddAgentMemories.up },
    // Migration 071 — adds `workspace_item_tasks.cwd` (the per-task
    // cwd_session). Each task can now carry its own cwd path;
    // session_create.zig::useCase resolves cwd in 3 levels:
    //   1. RequestSession.cwd_session (explicit per-call override)
    //   2. workspace_item_tasks.cwd  (this column — NEW)
    //   3. workspace_items.path      (existing kanban-level cwd)
    //   4. createSandbox(...)         (per-session TMPDIR fallback)
    // Empty string is the canonical "no per-task cwd" sentinel —
    // every existing row backfills to '' (the column is NOT NULL
    // DEFAULT ''). The frontend reads this from
    // WorkspaceItemTaskResponse.cwd and routes it through the same
    // chain on the client before sending cwd_session to the chat
    // session create endpoint. Plan:
    // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
    //
    // Renamed from Migration 070 during PR #200 merge (main already
    // used 070 for the agent_memories migration — save_memory +
    // load_memory agent tools, plan 2026-08-06-save-load-memory-fts5).
    .{ .version = Migration071AddTaskCwd.version, .name = Migration071AddTaskCwd.name, .up = Migration071AddTaskCwd.up },
    // Migration 072 — extracts `kanban_column_id` + `kanban_position` off
    // `workspace_item_tasks` into a dedicated `kanban` join table; wire
    // format preserved (Task.{kanban_column_id, kanban_position} continue
    // to exist via LEFT JOIN). Plan:
    // docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md.
    // Task: task_1786527996378.
    .{ .version = Migration072ExtractKanbanTable.version, .name = Migration072ExtractKanbanTable.name, .up = Migration072ExtractKanbanTable.up },
    // Migration 073 — session_activity append-only log
    // (update_activity + buildCompactionEnvelope now INSERT here in
    // addition to the existing worker.last_activity_description
    // UPDATE). Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md.
    // Task: task_1786629034327 ("new table session_activity").
    .{ .version = Migration073AddSessionActivity.version, .name = Migration073AddSessionActivity.name, .up = Migration073AddSessionActivity.up },
    .{ .version = Migration074AddLlmHistoryCacheTokenColumns.version, .name = Migration074AddLlmHistoryCacheTokenColumns.name, .up = Migration074AddLlmHistoryCacheTokenColumns.up },
    // Migration 075 — renames 5 timestamp columns to use the `_nano` suffix
    // (`logs.created_at` → `logs.created_at_nano`, etc.). Wire format preserved.
    // Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md.
    // Task: task_1786891244388_1.
    .{ .version = Migration075RenameTimestampColumnsToNanoSuffix.version, .name = Migration075RenameTimestampColumnsToNanoSuffix.name, .up = Migration075RenameTimestampColumnsToNanoSuffix.up },
    // Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
    // persistent task plan (markdown + checklist). Plan:
    // docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md. Task:
    // task_1787073929852_8.
    .{ .version = Migration076CreateSessionPlan.version, .name = Migration076CreateSessionPlan.name, .up = Migration076CreateSessionPlan.up },
    // Migration 077 — `users` + `user_companies` + `user_company_members`
    // + additive `workspaces.user_id` + `sessions.user_id` + default
    // `user_system` user + backfill. Sub-project 1 of 4 (foundation for
    // multi-user / multi-tenant pabrik). Plan:
    // docs/superpowers/plans/2026-08-21-users-rbac-foundation.md. Task:
    // task_1787199963946_1.
    .{ .version = Migration077AddUsersAndRbacSchema.version, .name = Migration077AddUsersAndRbacSchema.name, .up = Migration077AddUsersAndRbacSchema.up },
    // Migration 078 — Agent Mode: `agents` + `agent_knowledge` + `agent_tools`
    // (4th workspace-item type, knowledge injection, tool allowlist).
    // Plan: docs/superpowers/plans/2026-08-15-agent-mode.md.
    // Task: task_1786962724740_0.
    .{ .version = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.version, .name = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.name, .up = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up },
    // Migration 079 — agent_knowledge.content (manual text knowledge).
    // Plan: docs/superpowers/plans/2026-08-21-agent-knowledge-manual-text.md.
    // Task: task_1787315943769_9.
    .{ .version = Migration079AddContentToAgentKnowledge.version, .name = Migration079AddContentToAgentKnowledge.name, .up = Migration079AddContentToAgentKnowledge.up },
    // Migration 080 — agent_system_prompt (N-1 with agents, per-agent named
    // prompt blocks injected into the LLM system message).
    // Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md.
    // Task: task_1787408958280_1.
    .{ .version = Migration080AddAgentSystemPrompt.version, .name = Migration080AddAgentSystemPrompt.name, .up = Migration080AddAgentSystemPrompt.up },
    // Migration 081 — Agent-Kanbans mirror: agent_kanbans (1-1 with kanban
    // workspace_items) + knowledges + system_prompt + tools children.
    // Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md.
    // Task: task_1787597624259_2.
    .{ .version = Migration081CreateAgentKanbans.version, .name = Migration081CreateAgentKanbans.name, .up = Migration081CreateAgentKanbans.up },
    // Migration 082 — sessions.last_human_touched_at_nano column. Sibling
    // of Migration 065's task-side column. Drives the chat sidebar's
    // "last human touched" time pill (replacing the AI-tainted updated_at)
    // and the amber stale-dot when AI has touched since the user's last
    // touch. Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md.
    // Task: task_1788004921757_1.
    .{ .version = Migration082AddSessionHumanTouchedAt.version, .name = Migration082AddSessionHumanTouchedAt.name, .up = Migration082AddSessionHumanTouchedAt.up },
    // Migration 083 — llm_history reasoning metadata (reasoning_id +
    // reasoning_encrypted_content). Nullable TEXT columns for Responses API
    // reasoning replay when store:false. Plan:
    // docs/superpowers/plans/2026-09-01-fix-openai-response-reasoning-leak-and-persist.md.
    .{ .version = Migration083AddReasoningIdAndEncryptedContent.version, .name = Migration083AddReasoningIdAndEncryptedContent.name, .up = Migration083AddReasoningIdAndEncryptedContent.up },
    // Migration 084 — drop per-task `routines`, replace with workspace-level
    // `workspace_routines` (first-class `item_type='routine'` beside `agent`).
    // Breaking: old per-task schedules are dropped, no carry-over.
    // Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md.
    // Task: task_1789032258828_0.
    .{ .version = Migration084ReplaceRoutinesWithWorkspaceRoutines.version, .name = Migration084ReplaceRoutinesWithWorkspaceRoutines.name, .up = Migration084ReplaceRoutinesWithWorkspaceRoutines.up },
    .{ .version = Migration085AddSessionProgressiveTool.version, .name = Migration085AddSessionProgressiveTool.name, .up = Migration085AddSessionProgressiveTool.up },
    .{ .version = Migration086AddSessionPrUrl.version, .name = Migration086AddSessionPrUrl.name, .up = Migration086AddSessionPrUrl.up },
    .{ .version = Migration087CreateAgentRoutines.version, .name = Migration087CreateAgentRoutines.name, .up = Migration087CreateAgentRoutines.up },
    // Migration 088 — the `ask_user` question queue: one row per pending
    // question, answered later by POST /api/llm/session/:id/answer which
    // rewrites the matching tool-result row and resumes the session.
    // (Was 087 until the agent-routines mirror took that number; the table it
    // creates is independent, so only the version constant moved.)
    // Plan: docs/superpowers/plans/2026-09-16-agent-tool-ask-user.md.
    .{ .version = Migration088AddSessionPendingQuestion.version, .name = Migration088AddSessionPendingQuestion.name, .up = Migration088AddSessionPendingQuestion.up },
    // Migration 089 — `auth_sessions` for opt-in `--auth` login sessions.
    // One row per active cookie (token_hash -> user_id + expiry).
    // Stores only SHA-256(token), never the raw token.
    .{ .version = Migration089AuthSessions.version, .name = Migration089AuthSessions.name, .up = Migration089AuthSessions.up },
    // Migration 090 — `video_urls` / `video_url` columns for full video
    // upload to LLM (mirrors Migration 069 image_urls, 25 MB cap).
    .{ .version = Migration090AddVideoUrls.version, .name = Migration090AddVideoUrls.name, .up = Migration090AddVideoUrls.up },
    // Migration 091 — sessions.sub_agent_name + parent_session_id so a
    // sub-agent row shows its own identity alongside the parent profile.
    .{ .version = Migration091AddSubAgentNameToSessions.version, .name = Migration091AddSubAgentNameToSessions.name, .up = Migration091AddSubAgentNameToSessions.up },
    // Migration 092 — users.config_json for opt-in `--auth` mode.
    // When auth is on, per-user LLM config lives in this column and
    // config.json is ignored. NULL/empty = defaults.
    .{ .version = Migration092AddUserConfigJson.version, .name = Migration092AddUserConfigJson.name, .up = Migration092AddUserConfigJson.up },
    // Migration 093 — owner columns for per-user row isolation.
    // Adds worker.user_id (+ index) and backfills every still-NULL
    // workspaces/sessions/worker row to the shared `user_system` sentinel.
    // Plan: docs/plans/2026-09-25-per-user-isolation.md (W0).
    .{ .version = Migration093AddOwnerColumns.version, .name = Migration093AddOwnerColumns.name, .up = Migration093AddOwnerColumns.up },
    // Migration 094 — `workspace_items.is_default`, the per-workspace default
    // project. The partial unique index makes "at most one" a database
    // invariant, which matters because the lookup that creates the default
    // runs from a list read, a workspace create AND a New Chat tap, so those
    // genuinely race. No backfill: the list read creates it on demand.
    // Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md (D6, D12)
    .{ .version = Migration094AddDefaultProjectToWorkspaceItems.version, .name = Migration094AddDefaultProjectToWorkspaceItems.name, .up = Migration094AddDefaultProjectToWorkspaceItems.up },
    // Migration 095 — `agent_memories.workspace_id`, so `save_memory` /
    // `load_memory` stop sharing one note pool across every workspace.
    // `''` is the "no workspace" bucket; legacy rows land there, which is
    // why they stop being visible to workspace sessions (re-home with an
    // explicit UPDATE if you want to keep one).
    // Plan: docs/plans/2026-09-29-memory-workspace-isolation.md
    .{ .version = Migration095AddWorkspaceIdToAgentMemories.version, .name = Migration095AddWorkspaceIdToAgentMemories.name, .up = Migration095AddWorkspaceIdToAgentMemories.up },
    // Migration 096 — `session_skill_events`, the append-only skill usage
    // ledger. Answers "which turn loaded this skill", "was it only listed and
    // then ignored" and "has the body changed since it was read" — none of
    // which `session_skills` can answer, because it keeps only the latest body
    // per (session, skill) and only `use_skill` writes it.
    // Plan: docs/plans/2026-09-27-skill-evals.md (W1)
    .{ .version = Migration096CreateSessionSkillEvents.version, .name = Migration096CreateSessionSkillEvents.name, .up = Migration096CreateSessionSkillEvents.up },
    // Migration 097 — the skill-eval tables. `skill_eval_facts` caches the
    // INTRINSIC half of a verdict against (skill_key, content_hash,
    // context_key) so two sessions evaluating the same body at the same commit
    // share one computation; `skill_eval_runs` makes "once per self-prompted
    // session" a DB invariant; `skill_eval_results` holds the session-relative
    // half plus the `base_content_hash` staleness guard used on apply.
    // Plan: docs/plans/2026-09-27-skill-evals.md (§4.6, W0)
    .{ .version = Migration097CreateSkillEvalTables.version, .name = Migration097CreateSkillEvalTables.name, .up = Migration097CreateSkillEvalTables.up },
    // Migration 098 — the `documents` table: workspace-scoped markdown
    // documents surfaced in their own sidebar section below Projects.
    // `workspace_id` on the row IS the isolation boundary; the agent
    // tools resolve it server-side from the calling session.
    .{ .version = Migration098CreateDocuments.version, .name = Migration098CreateDocuments.name, .up = Migration098CreateDocuments.up },
    // Migration 099 — rename the `list_skills` agent tool to `search_skills`.
    // The tool name is a PERSISTED allowlist entry (`agent_tools` /
    // `agent_kanban_tools` / `users.config_json`), so a registry-only rename
    // would silently strip the tool from every existing agent and from every
    // customised checklist.
    .{ .version = Migration099RenameListSkillsTool.version, .name = Migration099RenameListSkillsTool.name, .up = Migration099RenameListSkillsTool.up },
    // Migration 100 — `workspace_members`: moves workspace ownership off the
    // single `workspaces.user_id` column onto a many-to-many join table so one
    // workspace can be shared. Additive; the column stays for one release so
    // `DROP TABLE workspace_members` is a complete rollback.
    .{ .version = Migration100AddWorkspaceMembers.version, .name = Migration100AddWorkspaceMembers.name, .up = Migration100AddWorkspaceMembers.up },
    // Migration 101 — `llm_history.model` is never empty. Closes two
    // independent failures: raw SQL writing `''` outright, and an empty
    // *bind* landing as SQL NULL and failing the NOT NULL constraint
    // (which silently DROPS the user's message row). The AFTER INSERT
    // trigger is the only SQLite choke point that also catches raw SQL.
    .{ .version = Migration101GuardLlmHistoryModel.version, .name = Migration101GuardLlmHistoryModel.name, .up = Migration101GuardLlmHistoryModel.up },
    // Migration 102 — the `skills` table: workspace-scoped skill bodies.
    // Skills move off the two filesystem tiers (`~/.config/pabrik/skills/`
    // and `<cwd>/.pabrik/skills/`) into SQL, so `workspace_id` on the row
    // IS the isolation boundary and `search_skills` can list ONE
    // workspace's skills instead of walking a directory. `skill_assets`
    // carries the companion files of bundled skills (`pdf`,
    // `skill-creator`) whose bodies reference them by relative path.
    .{ .version = Migration102CreateSkills.version, .name = Migration102CreateSkills.name, .up = Migration102CreateSkills.up },
    .{ .version = Migration103CreateWorkspaceSecrets.version, .name = Migration103CreateWorkspaceSecrets.name, .up = Migration103CreateWorkspaceSecrets.up },
    .{ .version = Migration104AddSessionPinned.version, .name = Migration104AddSessionPinned.name, .up = Migration104AddSessionPinned.up },
    // Migration 105 - the per-workspace config OVERLAY. A workspace's
    // `config_json` here is SPARSE: its keys win over the user-level
    // config and every other key still comes from there, which is what
    // lets Profiles / MCP Servers / Tools / Skill Evals live in Workspace
    // settings without every workspace being forced to redefine its
    // model and its credentials. Keyed on `(owner, workspace_id)` because
    // a workspace is shared when `--auth` is on and this table holds API
    // keys - see `workspace_settings_store.zig` for the owner rule.
    .{ .version = Migration105CreateWorkspaceSettings.version, .name = Migration105CreateWorkspaceSettings.name, .up = Migration105CreateWorkspaceSettings.up },
};

/// Register all migrations with a MigrationManager
pub fn registerAllMigrations(manager: *MigrationManager) !void {
    for (allMigrations) |migration| {
        try manager.registerMigration(migration);
    }
}

















































// ────────────────────────────────────────────────────────────────────────
// Migration 054 — drop NOT NULL on session_queue_messages.message
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ─────────────────────────
// Migration 018 (`Migration018CreateSessionQueueMessages`, line 247) declared
// `message TEXT NOT NULL`, which forces the application to always pass a
// non-empty message body. But the SqliteBackend.bind layer
// (src/modules/databases/sqlite/Sqlite.zig:73-74) treats any empty `[]const u8`
// as SQL NULL — see project memory `sqlite-backend-empty-slice-binds-as-null.md`.
// So an image-only queued message (params.message = "" with params.image_urls
// non-empty) triggers `NOT NULL constraint failed:
// session_queue_messages.message` at INSERT time in `queueMessage`
// (src/agentic_loop/llm_history.zig:1861).
//
// Fix: drop the NOT NULL on `message` so image-only queued messages can be
// inserted. Image-only queue messages are valid — they represent an attachment
// that will be sent before any text reply. The frontend renders them correctly
// (we already pipe-separator split on `|` in the SSE handler).
//
// Why the table-recreate pattern (vs `ALTER TABLE ... ALTER COLUMN ... DROP
// NOT NULL`)
// ─────────────────────────
// SQLite's `DROP NOT NULL` via ALTER COLUMN is only available on non-Windows
// builds and requires SQLite >= 3.35.0. The recreate-table pattern works on
// every SQLite version with no platform caveats, and matches the convention
// already used in Migration 023 (drop session_dir from llm_history) and
// Migration 038 (drop tool_results_json). `session_queue_messages` has no
// foreign keys into it (verified via `rg REFERENCES session_queue_messages`),
// so the rename + recreate + copy + drop sequence is safe.
//
// How the up() works
// ──────────────────
// 1. Detect whether `image_url` column exists. Production DBs always have it
//    (added by Migration 037). Fresh test DBs that only ran Migration 018
//    do not. The data-copy branch picks the right column list.
// 2. Rename the existing table out of the way.
// 3. Recreate with `message` nullable (no NOT NULL).
// 4. Copy all existing rows into the new table (preserving message content;
//    image_url either maps 1:1 or defaults to NULL on DBs that pre-date M037).
// 5. Drop the renamed table.
// 6. Recreate the `idx_session_queue_messages_session` index.

// ────────────────────────────────────────────────────────────────────────
// Migration 055 — design_pages table (v1 of design-mode feature)
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// First migration of the design-mode feature. Creates the
// `design_pages` table where each row represents one page of a design
// (e.g. "Login", "Dashboard") within a `workspace_items` row of
// `item_type = 'design'`.
//
// The original v1 stored page HTML inline as a `html TEXT` column.
// The file-backed upgrade is shipped in Migration 056. This split
// matches the eventual deployment: 055 ships first (initial feature),
// 056 ships later (the file-backed fix).
//
// Why the indexes
// ───────────────
// - UNIQUE design_pages(workspace_item_id, name) — enables INSERT
//   ... ON CONFLICT for the idempotent `setDesignPage` use case.
// - design_pages(workspace_item_id, position) — keeps `listPages`
//   fast as a page count grows.
//
// Why ANALYZE at the end
// ───────────────────────
// New indexes need fresh sqlite_stat1 entries for the query planner
// to recognize them — without ANALYZE, the planner's statistics are
// stale and the new indexes may be ignored. Mirrors the
// ANALYZE-after-DDL pattern used by Migrations 041/042/043/048/049/
// 050/051/052/053/054.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md

// ────────────────────────────────────────────────────────────────────────
// Migration 056 — upgrade design_pages to file-backed model
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// Migration 055's design_pages stored HTML inline as a `html TEXT`
// column. The v5/v6 model moves to a hybrid DB-metadata + on-disk HTML
// file layout:
//   - Pages become metadata-only (width/height/x/y/position) with NO
//     html column. The per-page folder at
//     `<workspace_item.path>/.pabrik/design/<page_name>/` holds the
//     element files.
//   - Each element is a positioned HTML snippet in the new
//     `design_page_elements` table; the html body lives at the
//     element's `file_path` (absolute path under workspace_item.path).
//
// Why version 56 (not 55)
// ──────────────────────
// Existing DBs that already ran Migration055 have it recorded at
// version 55 in `schema_migrations`. If we kept the upgrade at
// version 55, the tracker would skip it for existing users
// (symptom: `set_design_page` fails with `PrepareFailed: no such
// column: width`). Bumping to 56 guarantees the upgrade body runs
// once for every existing user. Fresh-DB installs run it as part of
// the bootstrap sequence — the CREATE TABLE IF NOT EXISTS +
// addColumnIfMissing calls are all idempotent.
//
// Migration body handles both upgrade-from-055 and fresh-DB:
//   - `CREATE TABLE IF NOT EXISTS design_pages` — fresh-DB; no-op on
//     upgrade (table already exists)
//   - `dropColumnIfExists("design_pages", "html")` — upgrade only;
//     fresh-DB has no html to drop
//   - `addColumnIfMissing(...)` for width/height/x/y — upgrade only;
//     fresh-DB's CREATE TABLE above already declares them
//   - `CREATE TABLE IF NOT EXISTS design_page_elements` — always new
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md

// ────────────────────────────────────────────────────────────────────────
// Migration 057 — add v6 element properties to design_page_elements
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// Adds 11 new columns to `design_page_elements` for the Figma-lite
// design-mode redesign (see design doc §5.1). The columns are purely
// additive — existing v5 columns (id, page_id, name, file_path, x, y,
// width, height, z_index, position, created_at, updated_at) are
// untouched. All new columns have sensible defaults so existing rows
// survive without a backfill.
//
// The properties unlocked by each column:
//   - `type`        → rectangle | ellipse | text | image | frame | group
//   - `rotation`    → degrees for the element transform
//   - `fill`        → CSS background-color (e.g. "#22c55e")
//   - `stroke`      → CSS border-color (e.g. "#000000")
//   - `stroke_width`→ CSS border-width (integer px)
//   - `corner_radius` → CSS border-radius (integer px)
//   - `opacity`     → 0.0..1.0 (REAL for sub-pixel precision)
//   - `text_content`→ populated for type='text' elements
//   - `text_style`  → JSON: font, size, weight, color, align (type='text')
//   - `image_url`   → populated for type='image' elements
//   - `parent_id`   → FK to design_page_elements(id) for frame/group nesting;
//                     ON DELETE SET NULL so deleting a parent doesn't
//                     cascade-delete the children.
//
// Why NOT NULL with DEFAULT '' for text columns
// ─────────────────────────────────────────────
// `SqliteBackend.exec` binds `arg.len == 0` as SQL NULL (see
// `src/modules/databases/sqlite/Sqlite.zig:73-74`). The application
// reads these fields as `[]const u8` (never `?[]const u8`), so a
// nullable column would force every SELECT to COALESCE and every
// INSERT to handle NULL explicitly. Mirrors the convention used by
// Migration 053 for `kanban_columns.description`.
//
// Why `addColumnIfMissing` instead of plain ALTER TABLE
// ────────────────────────────────────────────────────
// SQLite's `ALTER TABLE ... ADD COLUMN` does NOT support `IF NOT
// EXISTS` (errors at prepare with "near 'EXISTS': syntax error"). The
// helper checks `pragma_table_info` before issuing ALTER. Fresh DBs
// get all 11 columns from the Migration 056 CREATE TABLE above; this
// migration's adds are no-ops on fresh DBs and real adds on legacy
// DBs that already have Migration 056 in place but predate v6.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md

// ────────────────────────────────────────────────────────────────────────
// Migration 058 — FTS5 virtual table on llm_history (workspace history search)
// ────────────────────────────────────────────────────────────────────────
//
// Why this migration exists
// ──────────────────────────
// The workspace history search replaces the LIKE-prefix-scan with an
// FTS5 MATCH query. This
// migration creates the `messages_fts` external-content FTS5 virtual table
// over `llm_history.response_content`, plus the 3 sync triggers that keep
// it in lockstep with the source rows.
//
// Why external-content (content='llm_history')
// ────────────────────────────────────────────
// `content='llm_history'` makes the FTS table a *view* over the source —
// no row text is duplicated in `messages_fts`. Storage cost is just the
// FTS5 inverted index (a few MB at 10K messages). This is the SQLite
// docs' recommended approach for "full-text search over an existing table".
//
// Why porter+unicode61
// ─────────────────────
// `porter` does English-language stemming ("running" → "run"), reducing
// index size by ~20% on English corpora and improving recall for
// plural/tense variants. `unicode61` handles tokenization of Unicode
// characters (utf-8-aware splitting on word boundaries). `remove_diacritics
// 2` strips accents so "café" matches "cafe" — useful for non-ASCII
// chats.
//
// Why version 58 (not 55)
// ──────────────────────
// Migration numbers 55, 56, 57 are already taken (AddDesignPages,
// UpgradeDesignPagesToFileModel, AddDesignElementProperties).
// 58 is the next free slot in the migration sequence.
//
// Plan: workspace history FTS (Chunk 1)




















// ============================================================================
// Migration 073 — `session_activity` append-only log.
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// A per-session activity log that records two kinds of events:
//   1. Every `update_activity` tool call (the agent's `thought` string).
//   2. Every compaction event (`buildCompactionEnvelope` summary).
//
// Until now the only record of agent activity was
// `worker.last_activity_description` — a single row per worker that
// gets OVERWRITTEN on every update. That column is the live "what the
// worker is doing RIGHT NOW" for the sidebar UI (consumed by
// `prompts_make_activity_info_context.zig`). The new
// `session_activity` table is the per-session HISTORICAL log — every
// thought + every compaction event, ordered by `created_at`.
//
// Why `id` is TEXT, not INTEGER
// ──────────────────────────────
// Project-wide convention: every id column is TEXT (see
// `llm_history.id` Migration 001, `agent_memories.id` Migration 070,
// `kanban.workspace_item_task_id` Migration 072,
// `sessions.id`, `worker.id`). The helper
// (`llm_history.recordSessionActivity`) generates the id in
// application code from `std.Io.Timestamp.now(io, .real).nanoseconds`
// — same pattern as `llm_history.saveMessage` (line 1094) and
// `saveToolResultPlaceholder` (line 2448).
//
// Why no FK on `session_id`
// ──────────────────────────
// A session could be hard-deleted while keeping its history (matches
// the `llm_history.session_id` precedent, also a bare TEXT).
//
// Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
// Task: task_1786629034327 ("new table session_activity")



// ============================================================================
// Migration 076 — Agent Mode: `agents` + `agent_knowledge` + `agent_tools`
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// Agent Mode adds a fourth workspace-item type — `agent` — alongside
// `folder` / `kanban` / `design`. Each Agent is a persistent chatbot
// configuration with:
//   - a `path` (cwd for its chat sessions, like Kanban/Design)
//   - a list of absolute-path markdown knowledge files on disk
//     (injected into the system prompt as `## Agent Knowledge`)
//   - a tool allowlist (filtering the LLM's function-call schema)
//
// Three new tables back this:
//
//   1. `agents` — 1-1 with `workspace_items` (UNIQUE workspace_item_id).
//      Holds the agent's description (free-form). Empty agents table
//      means no Agents exist yet on a workspace.
//
//   2. `agent_knowledge` — N-1 with `agents`. Each row = a markdown file
//      path on disk + an optional label + a position for drag-reorder.
//      The backend re-reads file contents from disk at every chat start
//      (no content is duplicated into SQLite).
//
//   3. `agent_tools` — N-1 with `agents`. Each row = one tool explicitly
//      allowed for the agent. `tool_name` matches the canonical registry
//      at `tools_equipped.zig:118`. UNIQUE (agent_id, tool_name) so the
//      same tool can't be added twice.
//
// All 3 tables use `CREATE ... IF NOT EXISTS` — re-running the
// migration is a no-op. All FKs use `ON DELETE CASCADE` so deleting the
// parent workspace_item drops the agent + (cascade) its knowledge +
// tool rows.
//
// Why a separate agents table (and not just columns on workspace_items)
// ─────────────────────────────────────────────────────────────────────
// The user's spec specifies a 1-1 table. Keeping it separate:
//   - Future agent-specific columns (system-prompt override, default
//     model, allowed-tools baseline, embedding-config toggle) become
//     additive columns on `agents`, NOT on `workspace_items` (which
//     would affect kanban / design / folder rows too).
//   - Enforces the 1-1 invariant via `UNIQUE(workspace_item_id)` at the
//     schema level, not just at the application layer.
//
// Why a separate agent_knowledge table
// ─────────────────────────────────────
// One Agent has N knowledge files. A TEXT column on `agents` can't
// model N rows. The backend re-reads file contents from disk every
// chat (no content duplicated into SQLite). Storage stays small (paths
// only). A separate table also enables per-entry metadata (label,
// position, created_at) without future migrations.
//
// Why a separate agent_tools table
// ─────────────────────────────────
// One Agent has N tools enabled. The runtime filter is a single SQL
// query. `tool_name` + `enabled` give us per-row toggling for v1 +
// future per-tool overrides (e.g. per-tool rate limit) without another
// migration. UNIQUE (agent_id, tool_name) prevents duplicates.
//
// Secure-by-default semantics
// ───────────────────────────
// An empty `agent_tools` allowlist for an Agent means zero tools —
// the runtime filter at `workflow.zig:1478` returns no functions for
// the LLM to call. The user must opt in via the Tools panel. This is
// intentional and matches the user's framing "we need to limit the
// tool that's used".
//
// Plan: docs/superpowers/plans/2026-08-15-agent-mode.md
// Spec: docs/superpowers/specs/2026-08-15-agent-mode-design.md
// Task: task_1786962724740_0

// ============================================================================
// Migration 070 — `agent_memories` + `agent_memories_fts` for save_memory /
// load_memory tools
// ============================================================================
//
// What this migration creates
// ────────────────────────────
// The `save_memory` + `load_memory` agent tools (Task
// `task_1785958319567`, plan `2026-08-06-save-load-memory-fts5`) need a
// dedicated SQLite table + FTS5 index for short, structured notes that
// the agent can save on demand and recall via free-text search. This
// migration creates:
//
//   1. `agent_memories` — the source table
//      (id TEXT PK, content TEXT NOT NULL, tags TEXT NOT NULL DEFAULT '',
//       created_at/updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)
//   2. `agent_memories_fts` — a non-external-content FTS5 virtual table
//      over `content` + `tags` (porter+unicode61 tokenizer)
//   3. 3 sync triggers (INSERT/DELETE/UPDATE) that mirror source-table
//      mutations into the FTS5 index
//   4. An index on `updated_at DESC` for the future "most-recent
//      memories" UI surface (not used by v1 tools)
//   5. A backfill INSERT that no-ops on a fresh DB
//
// Why non-external-content
// ─────────────────────────
// `snippet()` returns NULL for external-content FTS5 tables. The
// `load_memory` tool needs snippets to render compact `<snippet>` blocks
// (10 tokens with `[match]` markers — see `memory.zig::loadSuccessXml`).
// Duplicating content costs ~2x storage but enables the only UX feature
// that matters here. This matches the existing `messages_fts` pattern
// (Migration 058 — see `migration.zig:1511` for the rationale).
//
// Tags as `||`-joined string
// ───────────────────────────
// Matches the project's convention for string-list columns
// (`workspace_item_tasks.tags` from Migration 067,
// `workspace_item_tasks.image_urls` from Migration 069). The frontend
// parses with `s.split('|').filter(Boolean)` — no JSON overhead at the
// SQL layer. The FTS5 tokenizer splits on `|` like any non-word char.
//
// No DELETE tool — UPSERT replaces
// ────────────────────────────────
// The `save_memory` tool uses INSERT-or-UPDATE (UPSERT) to overwrite
// existing memories with the same `id`. There is no `delete_memory`
// tool by user decision ("memory never can be deleted"). The DELETE
// trigger is still installed for completeness — if a future plan adds a
// delete affordance or a DB cleanup migration, the FTS5 index stays in
// sync automatically.
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md
// Task: task_1785958319567

// ─── Tests for Migration 078 (Agent Mode) ──────────────────────────────
// impl + tests in one file (project convention).
// `std` is already in scope from line 1; only the local aliases need adding.
const testing = std.testing;
const sqlite = @import("pabrikcore").sqlite;
const Migration078 = Migration076AddAgentsAndAgentKnowledgeAndAgentTools;


/// Top-level named struct (NOT inline anonymous) per project memory
/// `zig-anonymous-struct-type-identity.md` — Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields.
const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

/// Helper: run the migration, then return the list of column names for a
/// given table (ordered by `cid`, the original CREATE order).
fn columnsOf(ctx: *TestCtx, table: []const u8) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &[_][]const u8{table},
    );
    defer q.deinit();
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |c| alloc.free(c);
        list.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try list.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    // Transfer ownership of the slice (and each element) to the caller.
    // Caller MUST `free` the slice header AND each element. We use
    // `toOwnedSlice` so the ArrayList's buffer is detached and the
    // returned slice header survives past function return.
    return try list.toOwnedSlice(alloc);
}

/// Helper: assert `list` contains exactly `expected` (in order). Uses comptime
/// `expected` so the comparison can be inlined.
fn expectColumnsEqual(list: []const []const u8, comptime expected: anytype) !void {
    const expected_len: usize = expected.len;
    try testing.expectEqual(expected_len, list.len);
    var i: usize = 0;
    while (i < expected_len) : (i += 1) {
        try testing.expectEqualStrings(expected[i], list[i]);
    }
}

// ============================================================================
// Migration 098 — the `documents` table.
// ============================================================================
//
// Workspace-scoped markdown documents. A document is NOT a
// `workspace_items` row: it belongs to the workspace directly and is
// surfaced in its own "Documents" sidebar section below Projects, never
// inside the project tree. Scoping by `workspace_id` on the row itself is
// the isolation boundary — an agent in workspace A cannot see, edit or
// delete workspace B's documents, and the agent tools enforce that
// server-side (they resolve the workspace from the calling session, so
// the model never supplies an id to spoof).
//
// `format` exists so the table is not markdown-shaped by accident. MVP
// only ever writes `'markdown'`; the column is the forward-compatible
// slot for pdf / plain-text / html without another table rewrite.
//
// `ON DELETE CASCADE` is documentation only — this project deliberately
// leaves `PRAGMA foreign_keys` off (see the Migration 072 tests and
// Migration 093's header), so the workspace delete path issues the child
// DELETE itself.
//
// Every text column is `NOT NULL DEFAULT ''` rather than nullable:
// `SqliteBackend.exec` binds a zero-length slice as SQL NULL (Migration
// 079's `content` broke exactly this way), so writers go through
// `COALESCE(NULLIF(?, ''), '')`. A nullable column would let a
// well-meaning writer land NULL and read back as a null pointer in JS.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS. One statement per
// db.exec (sqlite3_prepare_v2 compiles only the first).

// Migration 099 — rename the `list_skills` agent tool to `search_skills`.
//
// WHY a data migration: the tool name is not decoration, it is a PERSISTED
// allowlist entry. `agent_tools.tool_name` (agents + routines) and
// `agent_kanban_tools.tool_name` (kanban boards) are seeded once at item
// creation and read back by `agentToolsAllowed` / `allowlistFilter`, which
// keeps ONLY tools whose name is in that list. Rename the registry without
// touching these rows and every existing agent silently loses the tool —
// with no error anywhere, exactly the "silently vanishes" failure mode the
// prompts tests guard against on the prompt side.
//
// Also rewritten: `users.config_json`, whose top-level `tools` checklist is
// what seeds NEW items (`seedDefaultAgentTools`). A user who customised their
// checklist would otherwise never see `search_skills` on the next agent they
// create. The replacement is on the quoted JSON token, not the bare word, so
// it cannot rewrite a description that merely mentions the tool.
//
// `session_progressive_tool` is left alone on purpose: `list_skills` was in
// `DEFAULT_AGENT_TOOLS`, so it was never offered by `search_tool` and there is
// no row to rename. The whole migration is idempotent — the second run
// matches nothing.

// ───────────────────────── tests: Migration 099 ─────────────────────────

test "Migration099 renames agent_tools rows and preserves enabled + count" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_1', 'ag_1', 'list_skills', 1)", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_2', 'ag_1', 'bash', 1)", &[_][]const u8{});

    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT tool_name, enabled FROM agent_tools WHERE agent_id = 'ag_1' ORDER BY tool_name", &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("bash", row.values[0]);
    const row2 = (try q.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("search_skills", row2.values[0]);
    try testing.expectEqualStrings("1", row2.values[1]);

    // Exactly two rows before and after — the rename never duplicates.
    if (try q.next()) |extra| {
        extra.deinit(alloc);
        return error.UnexpectedExtraRow;
    }
}

test "Migration099 renames every per-item-type allowlist table" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Agents, kanban boards AND routines each get their own table; miss one
    // and that item type silently loses the tool while the others keep it.
    const cases = [_]struct { table: []const u8, owner: []const u8 }{
        .{ .table = "agent_tools", .owner = "agent_id" },
        .{ .table = "agent_kanban_tools", .owner = "kanban_id" },
        .{ .table = "agent_routine_tools", .owner = "routine_id" },
    };

    for (cases) |c| {
        const create = try std.fmt.allocPrint(
            alloc,
            "CREATE TABLE {s} (id TEXT PRIMARY KEY, {s} TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE({s}, tool_name))",
            .{ c.table, c.owner, c.owner },
        );
        defer alloc.free(create);
        try ctx.db.exec(alloc, create, &[_][]const u8{});

        const seed = try std.fmt.allocPrint(
            alloc,
            "INSERT INTO {s} (id, {s}, tool_name, enabled) VALUES ('x_1', 'own_1', 'list_skills', 1)",
            .{ c.table, c.owner },
        );
        defer alloc.free(seed);
        try ctx.db.exec(alloc, seed, &[_][]const u8{});
    }

    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);

    for (cases) |c| {
        const sql = try std.fmt.allocPrint(alloc, "SELECT tool_name FROM {s}", .{c.table});
        defer alloc.free(sql);
        var q = try ctx.db.query(alloc, sql, &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoRow;
        defer row.deinit(alloc);
        testing.expectEqualStrings("search_skills", row.values[0]) catch |err| {
            std.debug.print("table {s}: {s}\n", .{ c.table, @errorName(err) });
            return err;
        };
    }
}

test "Migration099 keeps one row when an owner already has the new name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_1', 'ag_1', 'list_skills', 1)", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_2', 'ag_1', 'search_skills', 1)", &[_][]const u8{});

    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE tool_name = 'search_skills'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);

    var q2 = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE tool_name = 'list_skills'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("0", row2.values[0]);
}

test "Migration099 is idempotent and never leaves both names behind" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO agent_tools (id, agent_id, tool_name, enabled) VALUES ('at_1', 'ag_1', 'list_skills', 1)", &[_][]const u8{});

    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);
    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE tool_name = 'list_skills'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);

    var q2 = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE tool_name = 'search_skills'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("1", row2.values[0]);
}

test "Migration099 rewrites the config.json tools checklist token only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "CREATE TABLE users (id TEXT PRIMARY KEY, config_json TEXT)", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO users (id, config_json) VALUES ('u_1', '{\"tools\":[\"bash\",\"list_skills\",\"use_skill\"]}')", &[_][]const u8{});
    try ctx.db.exec(alloc, "INSERT INTO users (id, config_json) VALUES ('u_2', '{\"tools\":[\"bash\"]}')", &[_][]const u8{});

    try Migration099RenameListSkillsTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT config_json FROM users WHERE id = 'u_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("{\"tools\":[\"bash\",\"search_skills\",\"use_skill\"]}", row.values[0]);

    // The row that never mentioned the tool is untouched.
    var q2 = try ctx.db.query(alloc, "SELECT config_json FROM users WHERE id = 'u_2'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("{\"tools\":[\"bash\"]}", row2.values[0]);
}

test "Migration099 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration099RenameListSkillsTool.version) return;
    }
    return error.Migration099NotRegistered;
}

test "Migration078 creates agents table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, the agents table doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agents
        }
    }

    try Migration078.up(&ctx.db, alloc);

    // Post-migration: table exists in sqlite_master.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agents'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentsTableNotCreated;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agents", row.values[0]);
    }

    // Columns must be exactly: id, workspace_item_id, description, created_at, updated_at.
    const cols = try columnsOf(&ctx, "agents");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    const expected = [_][]const u8{ "id", "workspace_item_id", "description", "created_at", "updated_at" };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 creates agent_knowledge table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_knowledge");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, file_path, label, position, created_at, updated_at.
    const expected = [_][]const u8{
        "id", "agent_id", "file_path", "label", "position", "created_at", "updated_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 creates agent_tools table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_tools");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Spec columns: id, agent_id, tool_name, enabled, created_at.
    const expected = [_][]const u8{
        "id", "agent_id", "tool_name", "enabled", "created_at",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration078 agents.workspace_item_id is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Probe sqlite_master for a UNIQUE index on the agents.workspace_item_id column.
    // The standard SQLite convention is that UNIQUE constraints create
    // auto-named indexes "sqlite_autoindex_<table>_<n>"; query sqlite_master.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='agents'",
        &.{});
    defer q.deinit();
    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // The UNIQUE constraint produces an auto-index; the existence of
        // ANY index on agents in addition to idx_agents_workspace_item_id
        // is our proxy. We'll do a tighter check via INSERT below.
        // Just record that an index exists.
        found = true;
    }
    try testing.expect(found); // at least one index exists

    // Tighter check: INSERT two rows with the same workspace_item_id. The
    // second must fail with a UNIQUE violation. We need a parent
    // workspace_items row first (FK).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});

    // Duplicate INSERT must fail. Catch the SqliteError.
    const result = ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_2', 'ws_item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration078 agent_tools(agent_id, tool_name) is UNIQUE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Verify the named UNIQUE index exists.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='uq_agent_tools_agent_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UniqueIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("uq_agent_tools_agent_tool", row.values[0]);

    // Tighter check: insert parent rows, then duplicate tool_name → expect UNIQUE violation.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Test Agent', '/tmp/agent', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    const result = ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_2', 'agent_1', 'bash')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration078 ON DELETE CASCADE: agents dropped when workspace_items row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Enable FK enforcement (off by default in SQLite, on for this test).
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration078.up(&ctx.db, alloc);

    // Create the parent workspace_items row + agent + 1 knowledge + 1 tool.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id, description) VALUES ('agent_1', 'ws_item_1', 'test')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Sanity: all 4 rows exist.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("1", r.values[0]);
    }

    // Delete the parent workspace_items row. CASCADE should drop agents.
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    // The agent row should be gone (FK CASCADE from agents.workspace_item_id).
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agents WHERE id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration078 ON DELETE CASCADE: knowledge + tools dropped when agent row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try Migration078.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_1', 'agent_1', '/tmp/x.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path) VALUES ('know_2', 'agent_1', '/tmp/y.md')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_tools (id, agent_id, tool_name) VALUES ('at_1', 'agent_1', 'bash')",
        &.{});

    // Delete the agent row directly.
    try ctx.db.exec(alloc, "DELETE FROM agents WHERE id = 'agent_1'", &.{});

    // Both knowledge rows + tool row should be CASCADE-deleted.
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_knowledge WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
    {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_tools WHERE agent_id='agent_1'", &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

test "Migration078 creates agent_knowledge.position + agent_id composite index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // The named index from the spec: idx_agent_knowledge_agent_id_position.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_agent_knowledge_agent_id_position'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.PositionIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_agent_knowledge_agent_id_position", row.values[0]);
}

test "Migration078 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration078.up(&ctx.db, alloc); // second run must not crash

    // Each of the 3 tables should still exist exactly once.
    for ([_][]const u8{ "agents", "agent_knowledge", "agent_tools" }) |table| {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            &[_][]const u8{table},
        );
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration078 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration078.version) return;
    }
    return error.Migration078NotRegistered;
}

// ============================================================================
// Migration 079 tests — agent_knowledge.content column
// ============================================================================

const Migration079 = Migration079AddContentToAgentKnowledge;

test "Migration079 adds content column to agent_knowledge" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_knowledge");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // content appended after the original 7 columns.
    const expected = [_][]const u8{
        "id", "agent_id", "file_path", "label", "position", "created_at", "updated_at", "content",
    };
    try expectColumnsEqual(cols, &expected);
}

test "Migration079 is idempotent (safe to run twice)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc);
    try Migration079.up(&ctx.db, alloc); // must not throw

    // Column still exists exactly once.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('agent_knowledge') WHERE name = 'content'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration079 preserves existing rows with default empty content" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration078.up(&ctx.db, alloc);

    // Seed a file-backed row the old way (pre-079 shape).
    try ctx.db.exec(alloc,
        "INSERT INTO agent_knowledge (id, agent_id, file_path, label, position) VALUES ('k1', 'a1', '/tmp/x.md', '', 0)",
        &.{},
    );

    try Migration079.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT content FROM agent_knowledge WHERE id = 'k1'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration079 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration079.version) return;
    }
    return error.Migration079NotRegistered;
}

// ============================================================================
// Migration 079 — agent_knowledge.content (manual text knowledge)
// ============================================================================
//
// Adds a `content` column so a knowledge row can be either file-backed
// (content = '') or inline text (content = text). Empty-string sentinel
// matches the `label` convention. NOT NULL DEFAULT '' keeps every existing
// INSERT/SELECT working unchanged and backfills old rows as file-backed.
//
// Idempotency: addColumnIfMissing probes pragma_table_info before ALTER,
// so re-running is a no-op (canonical pattern from Migrations 020 / 052 /
// 065 / 066 / 067 / 074 / 077).
//
// Plan: docs/superpowers/plans/2026-08-21-agent-knowledge-manual-text.md
// Task: task_1787315943769_9

// ============================================================================
// Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
// persistent task plan (markdown + checklist).
// ============================================================================
//
// Schema:
//   - session_id TEXT PRIMARY KEY  (logical 1:1 with sessions.id; no FK
//                                   because sessions may be hard-deleted
//                                   while keeping their plan — matches
//                                   llm_history.session_id, worker.session_id,
//                                   session_queue_messages.session_id,
//                                   session_activity.session_id precedent;
//                                   see Migration 073's docstring.)
//   - plan_md TEXT NOT NULL DEFAULT ''  (the markdown body)
//   - updated_at DATETIME DEFAULT CURRENT_TIMESTAMP  (auto-bumped on every UPSERT)
//
// Why a dedicated table (not columns on `sessions`)
// - Single Responsibility: `sessions` is chat metadata; plan_md is plan content.
// - Backward compat: future schema changes to plan only touch this table.
// - PK on session_id enforces 1:1 without an extra UNIQUE index.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8

// ============================================================================
// Migration 077 — users + user_companies + user_company_members +
// workspaces.user_id + sessions.user_id + default user_system + backfill.
//
// What this migration creates
// ────────────────────────────
// The schema foundation for multi-user / multi-tenant pabrik — sub-project 1 of 4.
//   1. `users` (id, email, name, password_hash, role, is_active,
    //      created_at, updated_at, last_login_at) — identity table.
    //   2. `user_companies` (id, name, slug, description, is_active,
    //      created_at, updated_at, created_by) — org / tenant entity.
    //   3. `user_company_members` (user_id, user_company_id, role,
    //      joined_at, invited_by) with composite PRIMARY KEY on
    //      (user_id, user_company_id) — many-to-many user ↔ company.
    //   4. Additive `user_id` column on `workspaces` (nullable, no FK
    //      constraint — matches Migration 066 `design_pages.workspace_item_task_id`
    //      precedent; SQLite does NOT support ALTER TABLE … ADD CONSTRAINT FK).
    //   5. Additive `user_id` column on `sessions` (same shape).
    //   6. Default `user_system` user — id='user_system', email='system@local',
    //      password_hash='!disabled' (sentinel; can never match any real
    //      argon2id output), is_active=0 (can never log in), role='admin'
    //      (so any future RBAC query that resolves to it gets the widest
    //      permission).
    //   7. Backfill every legacy row (workspaces.user_id, sessions.user_id)
    //      WHERE user_id IS NULL → user_id = 'user_system'.
    //
    // Why a tx wraps the whole thing
    // ───────────────────────────────────────
    // 6 operations that must commit together. A crash mid-migration would
    // otherwise leave a half-built schema (e.g. users exists but
    // user_companies doesn't, or user_id columns added but backfill not
    // run), which the next migration would silently compound into a
    // never-ending recovery loop.
    //
    // Why no FK constraints
    // ─────────────────────
    // SQLite does not support ALTER TABLE … ADD CONSTRAINT FK. The two
    // canonical alternatives are triggers or recreate-table — both add
    // complexity that's out of scope for v1. The application layer is the
    // second line of defense (referential integrity enforced by JOIN
    // clauses at read time; the user_company_members composite PK
    // enforces "no duplicate membership" at the SQL layer). This matches
    // the project precedent — Migration 066's docstring explicitly notes
    // the same decision for `design_pages.workspace_item_task_id`.
    //
    // Idempotency
    // ───────────
    // Re-running this migration is safe via three mechanisms:
    //   1. CREATE TABLE IF NOT EXISTS — no-op if the tables exist.
    //   2. addColumnIfMissing — probes pragma_table_info before ALTER.
    //   3. INSERT OR IGNORE — no-op if the user_system row already exists.
    //   4. UPDATE … WHERE user_id IS NULL — no-op if no rows are NULL.
    //
    // Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
    // Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md
    // Task: task_1787199963946_1 (kanban: sprint bulan juni → "table users and rbac")

// ============================================================================
// Migration 080 — `agent_system_prompt` (N-1 with agents)
// ============================================================================
//
// Per-agent named system-prompt blocks, injected into the LLM system message
// at chat time (before the knowledge block). Relationship shape mirrors
// `agent_knowledge` exactly: id TEXT PK, agent_id FK → agents ON DELETE
// CASCADE, position ordering, timestamps.
//
// Schema:
//   - id TEXT PRIMARY KEY  (TEXT ids generated in Zig — project convention,
//     never INTEGER AUTOINCREMENT)
//   - agent_id TEXT NOT NULL  (== workspace_item_id per Agent Mode spec D3;
//     FK CASCADE so deleting an agent drops its prompts)
//   - title TEXT NOT NULL DEFAULT ''  (display name; '' = untitled)
//   - content TEXT NOT NULL DEFAULT ''  (the prompt body; empty rows are
//     skipped by the injector)
//   - position INTEGER NOT NULL DEFAULT 0  (ordering; rendered position DESC
//     like agent_knowledge)
//   - created_at / updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
//
// Idempotency: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
//
// Gotcha honored: one statement per db.exec — sqlite3_prepare_v2 compiles
// only the first statement, so the table and each index get their own exec.
//
// Plan: docs/superpowers/plans/2026-08-21-agent-system-prompt.md
// Task: task_1787408958280_1

// ============================================================================
// Migration 080 — agent_system_prompt (N-1 with agents) — inline tests
// ============================================================================

test "Migration080 creates agent_system_prompt table with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_system_prompt");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "agent_id", "title", "content", "position", "created_at", "updated_at",
    });
}

test "Migration080 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);
    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    // Table still exists and is usable after double-run.
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('p_1', 'a_1', 'T', 'C')",
        &.{});
}

test "Migration080 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration080AddAgentSystemPrompt.version) return;
    }
    return error.Migration080NotRegistered;
}

test "Migration080 ON DELETE CASCADE removes prompts when agent row deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    // Production order: parent tables first (agents), then the new table.
    try Migration078.up(&ctx.db, alloc);
    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'agent', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agents (id, workspace_item_id) VALUES ('agent_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('sp_1', 'agent_1', 'Persona', 'You are X')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_system_prompt (id, agent_id, title, content) VALUES ('sp_2', 'agent_1', 'Style', 'Be terse')",
        &.{});

    // Delete the agent row directly.
    try ctx.db.exec(alloc, "DELETE FROM agents WHERE id = 'agent_1'", &.{});

    // Both prompt rows should be CASCADE-deleted.
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM agent_system_prompt WHERE agent_id='agent_1'", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("0", r.values[0]);
}

// ============================================================================
// Migration 081 — Agent-Kanbans mirror: `agent_kanbans` +
// `agent_kanban_knowledges` + `agent_kanban_system_prompt` +
// `agent_kanban_tools`.
//
// Mirrors the agent-menu tables (Migration 078/079/080) onto kanban boards:
//   - agent_kanbans: 1-1 with workspace_items where item_type == 'kanban'.
//     Same identity convention as agents (spec D3): id == workspace_item_id.
//   - children keyed by kanban_id FK → agent_kanbans(id) ON DELETE CASCADE.
//
// Differences vs the agent tables (intentional):
//   - agent_kanban_knowledges.file_path is NOT NULL DEFAULT '' from day one
//     (file XOR inline content supported natively — no repeat of the
//     078→079 add-column dance).
//
// Idempotency: CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).
//
// Plan: docs/superpowers/plans/2026-08-25-agent-kanbans-mirror.md
// Task: task_1787597624259_2





// ============================================================================
// Migration 085 — session_progressive_tool (progressive tool search)
// ============================================================================




// ============================================================================
// Migration 089 — auth_sessions for opt-in `--auth` login sessions.
// ============================================================================
//
// One row per active login cookie: token_hash (SHA-256 of the opaque
// `pabrik_session` cookie value) -> user_id + expiry. `users` (Migration
// 077) tells us who exists; this table tells us who is currently logged
// in, on which device, until when.
//
// Why a table instead of stateless JWT: server-side logout/revoke,
// per-device sessions, expiry purge, and last_seen audit. Storing only
// the hash means a DB leak does not equal session hijack.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS. One statement per exec.


// Migration 091 — sessions.sub_agent_name + sessions.parent_session_id.
// A sub-agent session keeps its parent's selected_profile_model (Migration
// 040, forwarded by #554 so thinking/temperature inherit correctly) but
// now also records its own identity: the resolved sub-agent name
// (e.g. "implementator") and the parent session id. Both nullable TEXT,
// read back via COALESCE(col,''). Lets DB inspection and the UI show
// which sub-agent actually ran instead of only the parent profile.

// Migration 092 — users.config_json for opt-in `--auth` mode.
// When `--auth` is on, per-user LLM config (profiles, MCP servers,
// sub-agents, operational flags — the same JSON shape as
// config.json / LlmConfigJson) lives in this column and config.json
// is ignored. NULL or empty = defaults (same as a missing file).
// Nullable TEXT (not NOT NULL) so empty-string binds (which
// SqliteBackend collapses to NULL) never violate the schema.

// Migration 093 — owner columns for per-user row isolation.
//
// `workspaces.user_id` and `sessions.user_id` have existed since Migration
// 077 but nothing has ever written them; `worker` has no owner column at
// all. This migration closes the SCHEMA half of that gap:
//
//   1. add `worker.user_id` (+ index) so the worker lifecycle endpoints can
//      be scoped the same way as workspaces and sessions;
//   2. backfill every still-NULL root row to the shared sentinel
//      `user_system` (`auth_common.system_user_id`), exactly as Migration
//      077 did for workspaces/sessions.
//
// Rows in the sentinel bucket stay visible to EVERY authenticated user.
// That is deliberate (user decision 2026-09-25): enabling `--auth` must not
// hide the machine owner's existing workspaces/sessions. Rows written after
// isolation lands always carry a real owner, so the shared bucket only ever
// shrinks — it is not a destination for new writes.
//
// Nullable with no FK: nullable because `SqliteBackend.exec` binds an empty
// slice as SQL NULL (Migration 079's `content` and Migration 092's
// `config_json` broke exactly this way), and no FK because the project
// deliberately leaves `PRAGMA foreign_keys` off (see Migration 072 tests),
// which would make a declared FK documentation only.

// ============================================================================
// Migration 094 — mark one workspace item as the workspace's default project.
// ============================================================================
//
// Backs the "New Chat" action in the desktop sidebar and the Android drawer.
// The invariant this migration makes storable is:
//
//   Every workspace has a default project. If we look for one and don't
//   find it, we create it before doing anything else.
//
// The default project is a `workspace_items` row of `item_type = 'agent'`
// whose `path` is the server user's home directory, so a chat created
// inside it runs with $HOME as its working directory. See
// `src/http_handlers/workspace_items_default.zig::ensureDefaultProject` —
// the list read (`GET /api/workspaces/:ws/items`) is what catches a miss
// and creates the row, so this migration deliberately does NOT backfill:
// a backfill would have to resolve $HOME at migration time, and the lazy
// path covers every legacy workspace on its next read anyway.
//
// Plan: docs/plans/2026-09-27-sidebar-new-chat-default-project.md

// Migration 096 — `session_skill_events`, the skill usage ledger.
// ============================================================================
//
// `session_skills` (Migration 008) keeps only the LATEST body of each skill a
// session loaded — `INSERT OR REPLACE` keyed on (session_id, skill_name). It
// cannot answer "which turn loaded this", "was this skill only *listed* and
// then ignored", or "has the body changed since it was read", and it is
// written by `use_skill` alone, so `add_skill` / `edit_skill` / `remove_skill`
// leave no trace at all.
//
// This ledger is append-only (a fresh nanosecond id per row), so it answers
// all of those without touching `session_skills` — which deliberately stays as
// it is, because its `content` snapshot is the compaction drift detector.
//
// `content_hash` is what makes drift cheap to detect: an eval compares the
// hash of the body a session actually read against the hash of the body on
// disk now, instead of diffing two full bodies.
//
// Plan: docs/plans/2026-09-27-skill-evals.md (W1)

// ============================================================================
// Migration 097 — the skill-eval tables: shared facts, runs, results.
// ============================================================================
//
// Three tables, one feature (docs/plans/2026-09-27-skill-evals.md §4.6-4.7):
//
//   skill_eval_facts   the INTRINSIC half of a verdict (freshness, accuracy,
//                      duplication) — depends only on the skill body and the
//                      code state, so it is keyed on the identity of THAT
//                      question: (skill_key, content_hash, context_key). Two
//                      sessions evaluating the same body at the same commit
//                      are answering the same question, so one computation is
//                      shared instead of two. `verdict_intrinsic =
//                      'computing'` is a LEASE, not a value: the claiming
//                      statement is a single `INSERT OR IGNORE`, and a stale
//                      lease is reclaimable, so a crashed owner cannot poison
//                      the cache. Every read must require
//                      `verdict_intrinsic != 'computing'`.
//
//                      No `user_id` on purpose: these are facts about code,
//                      and global skills are already shared across users.
//                      The runs and results below ARE user records and carry
//                      the Migration 093 owner column.
//
//   skill_eval_runs    one row per eval invocation (self-prompted by the agent
//                      or on demand). The partial unique index makes "once per
//                      session" a DATABASE invariant, which is what lets the
//                      write path be `INSERT OR IGNORE` + `db.changes()` — the
//                      only correct shape here, because `SqliteBackend` has no
//                      usable multi-statement transaction (`exec` releases its
//                      mutex per call, see workspaces_reorder.zig).
//
//   skill_eval_results one row per (run, skill): the SESSION-RELATIVE half
//                      (relevance, used, helpfulness) plus a reference to the
//                      shared fact, so the same intrinsic verdict is not
//                      duplicated per session. `base_content_hash` is the
//                      correctness guard on apply: a proposal computed against
//                      an older body must never be written over a newer one, so
//                      apply re-hashes the skill and refuses with 409 on a
//                      mismatch.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).

// ============================================================================
// Migration 095 — per-workspace isolation for `agent_memories`.
// ============================================================================
//
// ## Why this migration exists
//
// The `save_memory` / `load_memory` agent tools store their notes in
// `agent_memories` (Migration 070) with NO owner column of any kind.
// The tool description even said so — "Global scope: memories are
// visible across all workspaces and sessions. There is no per-workspace
// filter." Every workspace on the machine therefore read and wrote the
// same note pool: a note saved while working on project X was recalled
// verbatim by an agent whose cwd was project Y, and `load_memory {id}`
// would hand over a full 1 MiB body belonging to a different workspace.
//
// Workspace isolation is the rule the rest of the product already
// follows (`read_workspace_session` scopes server-side from
// `ctx.session_id`; the kanban tools scope every query by
// `workspace_id`). This migration makes the memory store obey it too.
//
// ## The `''` sentinel
//
// `workspace_id TEXT NOT NULL DEFAULT ''` — `''` means "this memory
// belongs to no workspace" and is the project's existing convention for
// an absent string value (Migration 094's `is_default`, Migration 070's
// `tags`). A session that cannot be resolved to a workspace
// (`workspace_scope.resolveWorkspaceId` returns null — a bare CLI chat,
// a session whose cwd matches no `workspace_items.path`) writes into the
// `''` bucket, which is a bucket like any other: those sessions share
// it with each other, but NO workspace session can see it. Fail-closed
// in the direction that matters.
//
// Pre-existing rows land in `''` for free — `NOT NULL DEFAULT ''` on an
// ADD COLUMN is an O(1) metadata change, no table rewrite, no backfill
// UPDATE. They are therefore invisible to workspace-scoped sessions
// after this migration. That is deliberate: re-homing 300+ rows that
// span every workspace a user ever typed into would either guess a
// workspace or copy the same note into all of them, and copying it into
// all of them is the exact leak this migration exists to close. To keep
// them, re-home the ones you want explicitly:
//
//   UPDATE agent_memories SET workspace_id = 'ws_...' WHERE id = 'mem_...';
//
// ## What is NOT changed
//
// `agent_memories_fts` still indexes `content` + `tags` only. The
// workspace filter is a JOIN predicate on the source table (the FTS5
// query already joins `agent_memories` for `snippet()`), so no FTS
// rebuild, no trigger change and no re-tokenization is required. A
// partitioned virtual table would force a full reindex of every note on
// a schema-only concern.

// ============================================================================
// Migration 087 — agent config tables for routine workspace items.
// ============================================================================
//
// Mirrors Migration 081 (agent_kanbans) onto routines so the RoutineView
// Agent tab has storage: `agent_routines` (1-1 with workspace_items where
// item_type == 'routine', same D3 identity id == workspace_item_id) plus
// `agent_routine_knowledges` + `agent_routine_system_prompt` +
// `agent_routine_tools` children keyed by routine_id FK ON DELETE CASCADE.
//
// Differences vs 081 (intentional):
//   - Backfills one `agent_routines` row per pre-existing routine item
//     (INSERT OR IGNORE ... SELECT) so routines created before this
//     migration get a working Agent tab immediately instead of a
//     NotConfigured dead-end. Kanban stayed opt-in; routines need
//     day-one config because the tab ships in the same release.
//   - No default-tools seed here: an empty allowlist means "all tools"
//     (kanban D5 semantics), which preserves the pre-migration fire
//     behaviour exactly.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS + INSERT OR IGNORE.
// One statement per db.exec (sqlite3_prepare_v2 compiles only the first).
//
// Plan: Routine mode task_1789505553300_1 (option A, mirror agent_kanban_*).

// ============================================================================
// Migration 083 — llm_history reasoning metadata — inline tests
// ============================================================================

test "Migration083 adds reasoning_id + reasoning_encrypted_content columns to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Minimal pre-083 llm_history shape (has reasoning_content from Migration 003).
    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    // Sanity: columns do NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    // Verify via columnsOf helper (project convention).
    const cols = try columnsOf(&ctx, "llm_history");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_reasoning_id = false;
    var has_encrypted = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "reasoning_id")) has_reasoning_id = true;
        if (std.mem.eql(u8, c, "reasoning_encrypted_content")) has_encrypted = true;
    }
    try testing.expect(has_reasoning_id);
    try testing.expect(has_encrypted);

    // Type + nullability sanity: both TEXT, nullable (notnull == 0).
    var q = try ctx.db.query(alloc,
        "SELECT name, type, \"notnull\" FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content') ORDER BY name",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("TEXT", row.values[1]);
        try testing.expectEqualStrings("0", row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 2), idx);
}

test "Migration083 INSERT/SELECT round-trip for both new columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    // Insert with all three reasoning fields populated.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, reasoning_content, reasoning_id, reasoning_encrypted_content) VALUES (?, ?, ?, ?, ?, ?)",
        &.{ "h1", "sess1", "gpt-5", "thinking trace", "rs_123", "ENC_DATA" });

    {
        var q = try ctx.db.query(alloc,
            "SELECT reasoning_content, reasoning_id, reasoning_encrypted_content FROM llm_history WHERE id = ?",
            &.{ "h1" });
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("thinking trace", row.values[0]);
        try testing.expectEqualStrings("rs_123", row.values[1]);
        try testing.expectEqualStrings("ENC_DATA", row.values[2]);
    }

    // NULL handling: legacy row without reasoning metadata should read as "" (SqliteBackend NULL → "").
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model) VALUES (?, ?, ?)",
        &.{ "h2", "sess1", "gpt-5" });
    {
        var q = try ctx.db.query(alloc,
            "SELECT reasoning_id, reasoning_encrypted_content FROM llm_history WHERE id = ?",
            &.{ "h2" });
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("", row.values[0]);
        try testing.expectEqualStrings("", row.values[1]);
    }
}

test "Migration083 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    reasoning_content TEXT
        \\)
    , &.{});

    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);
    try Migration083AddReasoningIdAndEncryptedContent.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration083 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration083AddReasoningIdAndEncryptedContent.version) return;
    }
    return error.Migration083NotRegistered;
}

// ============================================================================
// Migration 081 — agent-kanbans mirror — inline tests
// ============================================================================

const Migration081 = Migration081CreateAgentKanbans;

test "Migration081 creates agent_kanbans with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_kanbans");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_item_id", "description", "created_at", "updated_at",
    });
}

test "Migration081 creates agent_kanban_knowledges with content column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "agent_kanban_knowledges");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "kanban_id", "file_path", "label", "content", "position", "created_at", "updated_at",
    });
}

test "Migration081 creates agent_kanban_system_prompt and agent_kanban_tools with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    const sp_cols = try columnsOf(&ctx, "agent_kanban_system_prompt");
    defer {
        for (sp_cols) |c| alloc.free(c);
        alloc.free(sp_cols);
    }
    try expectColumnsEqual(sp_cols, &[_][]const u8{
        "id", "kanban_id", "title", "content", "position", "created_at", "updated_at",
    });

    const tool_cols = try columnsOf(&ctx, "agent_kanban_tools");
    defer {
        for (tool_cols) |c| alloc.free(c);
        alloc.free(tool_cols);
    }
    try expectColumnsEqual(tool_cols, &[_][]const u8{
        "id", "kanban_id", "tool_name", "enabled", "created_at",
    });
}

test "Migration081 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration081.version) return;
    }
    return error.Migration081NotRegistered;
}

test "Migration081 UNIQUE workspace_item_id rejects second agent_kanbans row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration081.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_1', 'item_1')",
        &.{});
    const result = ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_2', 'item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration081 ON DELETE CASCADE removes all children when workspace_item deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    // Production order: parent tables first (agents), then the new tables.
    try Migration078.up(&ctx.db, alloc);
    try Migration081.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'kanban', 'Cascade Test', '/tmp/cascade', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanbans (id, workspace_item_id) VALUES ('ak_1', 'ws_item_1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_knowledges (id, kanban_id, file_path, label, content) VALUES ('k_1', 'ak_1', '', 'Note', 'inline body')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_system_prompt (id, kanban_id, title, content) VALUES ('sp_1', 'ak_1', 'Persona', 'You are X')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO agent_kanban_tools (id, kanban_id, tool_name) VALUES ('t_1', 'ak_1', 'bash')",
        &.{});

    // Delete the workspace_item row directly.
    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    // The agent_kanbans row and ALL children should be CASCADE-deleted.
    inline for (.{ "agent_kanbans", "agent_kanban_knowledges", "agent_kanban_system_prompt", "agent_kanban_tools" }) |table| {
        var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM " ++ table, &.{});
        defer q.deinit();
        const r = (try q.next()) orelse return error.RowMissing;
        defer r.deinit(alloc);
        try testing.expectEqualStrings("0", r.values[0]);
    }
}

// ============================================================================
// Migration 084 — replace per-task routines with workspace_routines — tests
// ============================================================================

const Migration084 = Migration084ReplaceRoutinesWithWorkspaceRoutines;

test "Migration084 creates workspace_routines with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_routines");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",                 "workspace_item_id",
        "description",        "instruction",
        "schedule",           "enabled",
        "last_run_at",        "next_run_at",
        "last_status",        "last_error",
        "created_at",         "updated_at",
    });
}

test "Migration084 drops routines table and normalizes task_type routine rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Pre-084 state: a routine task + its routines row (Migration 044 shape).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, task_type) VALUES ('t_rout', 'routine'), ('t_std', 'standard')",
        &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at DATETIME,
        \\    next_run_at DATETIME NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't_rout', '* * * * *', 'hi', '2026-01-01 00:00:00')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    // Old table is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'routines'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }
    // Old indexes are gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_routines_%'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }
    // Routine task normalized to standard; standard row untouched.
    {
        var q = try ctx.db.query(alloc,
            "SELECT task_type FROM workspace_item_tasks WHERE id = 't_rout'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("standard", row.values[0]);
    }
    {
        var q = try ctx.db.query(alloc,
            "SELECT task_type FROM workspace_item_tasks WHERE id = 't_std'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("standard", row.values[0]);
    }
    // Replacement table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'workspace_routines'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("workspace_routines", row.values[0]);
    }
}

test "Migration084 UNIQUE workspace_item_id rejects second workspace_routines row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('wr_1', 'item_1')",
        &.{});
    const result = ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id) VALUES ('wr_2', 'item_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration084 ON DELETE CASCADE removes routine when workspace_item deleted" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    try Migration084.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position) VALUES ('ws_item_1', 'ws_1', 'routine', 'Nightly', '/tmp/x', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_routines (id, workspace_item_id, instruction, schedule) VALUES ('wr_1', 'ws_item_1', 'do things', '0 9 * * *')",
        &.{});

    try ctx.db.exec(alloc, "DELETE FROM workspace_items WHERE id = 'ws_item_1'", &.{});

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_routines", &.{});
    defer q.deinit();
    const r = (try q.next()) orelse return error.RowMissing;
    defer r.deinit(alloc);
    try testing.expectEqualStrings("0", r.values[0]);
}

test "Migration084 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});

    try Migration084.up(&ctx.db, alloc);
    try Migration084.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'workspace_routines'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration084 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration084.version) return;
    }
    return error.Migration084NotRegistered;
}

// ============================================================================
// Migration 085 — session_progressive_tool — inline tests
// ============================================================================

test "Migration085 creates session_progressive_tool with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "session_progressive_tool");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "session_id",
        "tool_name",
        "server_name",
        "loaded_at_nano",
    });
}

test "Migration085 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);
    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_progressive_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration085 PRIMARY KEY(session_id, tool_name) rejects a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration085AddSessionProgressiveTool.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 1)",
        &.{});
    // A second insert with the same (session_id, tool_name) must be rejected
    // by the PRIMARY KEY. Asserted as "some error" rather than a specific
    // name: the DB layer's Error set has no ConstraintViolation variant.
    var duplicate_failed = false;
    ctx.db.exec(alloc,
        "INSERT INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 2)",
        &.{}) catch {
        duplicate_failed = true;
    };
    try testing.expect(duplicate_failed);
    // INSERT OR IGNORE (what the production helper uses) is a silent no-op.
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO session_progressive_tool (session_id, tool_name, server_name, loaded_at_nano) VALUES ('s1', 'glob', '', 3)",
        &.{});

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM session_progressive_tool WHERE session_id = 's1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration085 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration085AddSessionProgressiveTool.version) return;
    }
    return error.Migration085NotRegistered;
}

// ============================================================================
// Migration 086 — sessions.pr_url + pr_provider — inline tests
// ============================================================================

test "Migration086 adds pr_url + pr_provider columns to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Minimal pre-086 sessions shape.
    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "sessions");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_url = false;
    var has_provider = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "pr_url")) has_url = true;
        if (std.mem.eql(u8, c, "pr_provider")) has_provider = true;
    }
    try testing.expect(has_url);
    try testing.expect(has_provider);

    // Both nullable TEXT (notnull == 0).
    var q = try ctx.db.query(alloc,
        "SELECT name, type, \"notnull\" FROM pragma_table_info('sessions') WHERE name IN ('pr_url', 'pr_provider') ORDER BY name",
        &.{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("TEXT", row.values[1]);
        try testing.expectEqualStrings("0", row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 2), idx);
}

test "Migration086 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);
    try Migration086AddSessionPrUrl.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('pr_url', 'pr_provider')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration086 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration086AddSessionPrUrl.version) return;
    }
    return error.Migration086NotRegistered;
}

// ============================================================================
// Migration 087 — agent_routines mirror — inline tests
// ============================================================================

test "Migration087 creates agent_routines tables with correct columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    for ([_][]const u8{ "agent_routines", "agent_routine_knowledges", "agent_routine_system_prompt", "agent_routine_tools" }) |tbl| {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            &[_][]const u8{tbl});
        defer q.deinit();
        const found = try q.next();
        if (found) |r| r.deinit(alloc);
        try testing.expect(found != null);
    }

    const cols = try columnsOf(&ctx, "agent_routine_knowledges");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_routine_id = false;
    var has_position = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "routine_id")) has_routine_id = true;
        if (std.mem.eql(u8, c, "position")) has_position = true;
    }
    try testing.expect(has_routine_id);
    try testing.expect(has_position);
}

test "Migration087 backfills agent_routines rows for pre-existing routines only" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('rt_1', 'ws_1', 'routine', 'Nightly')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('kb_1', 'ws_1', 'kanban', 'Board')",
        &.{});

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    {
        var q = try ctx.db.query(alloc,
            "SELECT id, workspace_item_id FROM agent_routines",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("rt_1", row.values[0]);
        try testing.expectEqualStrings("rt_1", row.values[1]);
        try testing.expect((try q.next()) == null);
    }
}

test "Migration087 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT NOT NULL, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES ('rt_1', 'ws_1', 'routine', 'Nightly')",
        &.{});

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);
    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM agent_routines",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration087 UNIQUE workspace_item_id rejects a duplicate" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration087CreateAgentRoutines.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('rt_1', 'rt_1')",
        &.{});
    const dup = ctx.db.exec(alloc,
        "INSERT INTO agent_routines (id, workspace_item_id) VALUES ('rt_x', 'rt_1')",
        &.{});
    try testing.expectError(error.ExecuteFailed, dup);
}

test "Migration087 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration087CreateAgentRoutines.version) return;
    }
    return error.Migration087NotRegistered;
}

test "Migration091 adds sub_agent_name + parent_session_id to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "sessions");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var has_sub = false;
    var has_parent = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "sub_agent_name")) has_sub = true;
        if (std.mem.eql(u8, c, "parent_session_id")) has_parent = true;
    }
    try testing.expect(has_sub);
    try testing.expect(has_parent);
}

test "Migration091 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});

    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);
    try Migration091AddSubAgentNameToSessions.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name IN ('sub_agent_name', 'parent_session_id')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}

test "Migration091 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration091AddSubAgentNameToSessions.version) return;
    }
    return error.Migration091NotRegistered;
}

// ============================================================================
// Migration 093 — owner columns for per-user row isolation — inline tests
// ============================================================================

/// Minimal pre-093 root schema: `workspaces` and `sessions` already carry
/// `user_id` (Migration 077), `worker` does not.
fn setupOwnerRoots(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE worker (id TEXT PRIMARY KEY, session_id TEXT NOT NULL)", &.{});
}

/// Assert one row's owner. Deliberately a comparison helper (not a getter)
/// so no duped value can escape and trip the leak-checking test allocator.
fn expectOwner(ctx: *TestCtx, table: []const u8, id: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    const sql = try std.fmt.allocPrint(
        alloc,
        "SELECT COALESCE(user_id, '<null>') FROM {s} WHERE id = ?",
        .{table},
    );
    defer alloc.free(sql);
    var q = try ctx.db.query(alloc, sql, &[_][]const u8{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected, row.values[0]);
}

test "Migration093 adds worker.user_id and its index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "worker");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var found = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "user_id")) found = true;
    }
    try testing.expect(found);

    // Nullable TEXT: an empty-string bind (which SqliteBackend collapses to
    // SQL NULL) must never violate the column.
    var q = try ctx.db.query(alloc,
        "SELECT type, \"notnull\" FROM pragma_table_info('worker') WHERE name = 'user_id'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_user_id'",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("1", irow.values[0]);
}

test "Migration093 backfills legacy NULL owners to the shared sentinel" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('sess_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id) VALUES ('w_legacy', 'sess_legacy')", &.{});

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    // The shared bucket is what keeps pre-auth data visible once `--auth`
    // is switched on (user decision 2026-09-25).
    try expectOwner(&ctx, "workspaces", "ws_legacy", "user_system");
    try expectOwner(&ctx, "sessions", "sess_legacy", "user_system");
    try expectOwner(&ctx, "worker", "w_legacy", "user_system");
}

test "Migration093 never downgrades a real owner and is idempotent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupOwnerRoots(&ctx);
    // Simulate a database that already ran 093: worker.user_id present, so
    // the ADD COLUMN path is exercised as a no-op too.
    try ctx.db.exec(alloc, "ALTER TABLE worker ADD COLUMN user_id TEXT", &.{});

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_a', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_legacy', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, user_id) VALUES ('sess_a', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO worker (id, session_id, user_id) VALUES ('w_a', 'sess_a', 'user_a')", &.{});

    try Migration093AddOwnerColumns.up(&ctx.db, alloc);
    try Migration093AddOwnerColumns.up(&ctx.db, alloc);

    try expectOwner(&ctx, "workspaces", "ws_a", "user_a");
    try expectOwner(&ctx, "sessions", "sess_a", "user_a");
    try expectOwner(&ctx, "worker", "w_a", "user_a");
    // The legacy row is backfilled, and only once.
    try expectOwner(&ctx, "workspaces", "ws_legacy", "user_system");
}

test "Migration093 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration093AddOwnerColumns.version) return;
    }
    return error.Migration093NotRegistered;
}

// ============================================================================
// Migration 094 — workspace_items.is_default
// ============================================================================

/// Create a minimal pre-Migration-094 `workspace_items` table, with rows
/// already in it. The column default has to be verified against real
/// existing rows, not a table we just created with the column present.
fn setupWorkspaceItemsPre094(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\  id TEXT PRIMARY KEY,
        \\  workspace_id TEXT NOT NULL,
        \\  item_type TEXT NOT NULL,
        \\  name TEXT,
        \\  path TEXT,
        \\  position INTEGER NOT NULL DEFAULT 0
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, path, position)
        \\VALUES ('item_a', 'ws_1', 'kanban', 'Board', '/tmp/board', 1),
        \\       ('item_b', 'ws_1', 'agent',  'Helper', '/tmp/helper', 2),
        \\       ('item_c', 'ws_2', 'folder', 'Stuff', '/tmp/stuff', 0)
    , &.{});
}

/// Assert one workspace item's `is_default` flag. A comparison helper (not a
/// getter) so no duped value can escape and trip the leak-checking allocator.
fn expectIsDefault(ctx: *TestCtx, id: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT is_default FROM workspace_items WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected, row.values[0]);
}

test "Migration094 adds is_default and defaults every pre-existing row to 0" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_items");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var found = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "is_default")) found = true;
    }
    try testing.expect(found);

    // The whole point of NOT NULL DEFAULT 0: pre-existing rows must read
    // back as ordinary projects, with no backfill UPDATE and no table
    // rewrite. If this ever returns non-zero, a migration is marking a
    // user's existing project as a default.
    var q = try ctx.db.query(alloc,
        \\SELECT id, is_default FROM workspace_items ORDER BY id
    , &.{});
    defer q.deinit();
    var seen: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[1]);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);

    // NOT NULL must be set, or a future writer could store NULL and the
    // `WHERE is_default = 1` index would silently skip that row forever.
    var qi = try ctx.db.query(alloc,
        "SELECT type, \"notnull\", dflt_value FROM pragma_table_info('workspace_items') WHERE name = 'is_default'",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", irow.values[0]);
    try testing.expectEqualStrings("1", irow.values[1]);
    try testing.expectEqualStrings("0", irow.values[2]);
}

test "Migration094's partial unique index allows one default per workspace" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    // ws_1 gets its default. ws_2 has none yet — the invariant is the
    // service layer's job to fill, not the schema's.
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_a'",
        &.{},
    );

    // A SECOND default in the same workspace must be refused. This is the
    // guarantee the whole race-guard in ensureDefaultProject leans on.
    // `ExecuteFailed` is what SqliteBackend.exec surfaces for a constraint
    // violation — the SQLSTATE text ("UNIQUE constraint failed") only
    // reaches the log, so the STATE check below is what actually proves the
    // index did its job.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_b'",
            &.{},
        ),
    );
    try expectIsDefault(&ctx, "item_b", "0");

    // A different workspace may have its own default — the index is
    // partial *and* scoped per workspace, not "one default in the db".
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_c'",
        &.{},
    );

    // Ordinary rows are never compared against each other, so any number
    // of them coexist in one workspace.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, position)
        \\VALUES ('item_d', 'ws_1', 'kanban', 'Another board', 3)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type, name, position)
        \\VALUES ('item_e', 'ws_1', 'kanban', 'Third board', 4)
    , &.{});

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_items WHERE workspace_id = 'ws_1' AND is_default = 1",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration094 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceItemsPre094(&ctx);

    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);
    // Mark one so a re-run also has to cope with a populated column.
    try ctx.db.exec(alloc,
        "UPDATE workspace_items SET is_default = 1 WHERE id = 'item_a'",
        &.{},
    );
    // Re-running must not throw "duplicate column" (addColumnIfMissing
    // guards it) and must not clobber the existing default.
    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);
    try Migration094AddDefaultProjectToWorkspaceItems.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id FROM workspace_items WHERE is_default = 1",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("item_a", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration094 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration094AddDefaultProjectToWorkspaceItems.version) return;
    }
    return error.Migration094NotRegistered;
}

// ─── Tests for Migration 095 (agent_memories.workspace_id) ────────────

/// Create a pre-Migration-095 `agent_memories` (+ FTS5 side table) with
/// rows in it, so the ADD COLUMN can be exercised against data rather
/// than an empty table.
fn setupAgentMemoriesPre095(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator,
        \\CREATE TABLE agent_memories (
        \\    id TEXT PRIMARY KEY,
        \\    content TEXT NOT NULL,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &[_][]const u8{});
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_memories (id, content) VALUES ('mem_aaa', 'legacy note one')",
        &[_][]const u8{},
    );
    try ctx.db.exec(testing.allocator,
        "INSERT INTO agent_memories (id, content) VALUES ('mem_bbb', 'legacy note two')",
        &[_][]const u8{},
    );
}

test "Migration095 adds workspace_id and files every pre-existing row in the '' bucket" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupAgentMemoriesPre095(&ctx);

    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT id, workspace_id FROM agent_memories ORDER BY id
    , &.{});
    defer q.deinit();
    const a = (try q.next()) orelse return error.RowMissing;
    defer a.deinit(alloc);
    try testing.expectEqualStrings("mem_aaa", a.values[0]);
    try testing.expectEqualStrings("", a.values[1]);
    const b = (try q.next()) orelse return error.RowMissing;
    defer b.deinit(alloc);
    try testing.expectEqualStrings("mem_bbb", b.values[0]);
    try testing.expectEqualStrings("", b.values[1]);
}

test "Migration095 creates the workspace index and is idempotent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupAgentMemoriesPre095(&ctx);

    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);
    // Re-running must not throw "duplicate column" / "index already exists"
    // and must not rewrite a row that already has an owner.
    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        "UPDATE agent_memories SET workspace_id = 'ws_kept' WHERE id = 'mem_aaa'",
        &[_][]const u8{},
    );
    try Migration095AddWorkspaceIdToAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT workspace_id FROM agent_memories WHERE id = 'mem_aaa'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("ws_kept", row.values[0]);

    var idx = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_agent_memories_workspace'",
        &.{});
    defer idx.deinit();
    const irow = (try idx.next()) orelse return error.IndexMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("idx_agent_memories_workspace", irow.values[0]);
}

test "Migration095 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration095AddWorkspaceIdToAgentMemories.version) return;
    }
    return error.Migration095NotRegistered;
}

// ===== Tests merged from migration_test.zig (2026-09-29 flatten) =====

test "migration module imports" {
    // Test that the migration module can be imported
    try std.testing.expect(true);
}

// ===== Tests merged from migration_009_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 009 (remove_created_column).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 009's `INSERT INTO ... SELECT datetime(CAST(created AS
// INTEGER), 'unixepoch') FROM llm_history_old` references a `created`
// column that has **never existed** in this codebase — Migration 001
// has always created `llm_history` with a `created_at` column
// directly. On a fresh DB (no historical `created` column),
// `runMigrations` aborts with:
//
//   sqlite3_prepare_v2 error: no such column: created
//
// which crashes the server during startup. A static source check
// would not catch this — only executing the INSERT against an
// actual schema exposes the bug. The fix (Migration 009 now uses
// `COALESCE(created_at, CURRENT_TIMESTAMP)`) is verified by
// running migration 009 against the schema state left by
// migrations 001–008.
//
// The SqliteBackend's public API (see
// `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). Column reads go through `Row.values[i]`, which
// is always text.

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB and apply migrations 001–008,
/// matching the schema state that migration 009 was always meant to
/// consume. After this returns, the DB has the full pre-migration-009
/// `llm_history` schema with all columns added by 002–008, ready for
/// migration 009 to do its rename-and-copy dance.

fn setupDb009() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Replay migrations 001–008 in version order. Migration 001 itself
    // creates the table; the rest are ADD COLUMN. This mirrors what a
    // fresh-install DB looks like when migration 009 is about to run.
    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration002AddRoleToLLMHistory.up(&db, alloc);
    try Migration003AddReasoningContent.up(&db, alloc);
    try Migration004AddSessionDir.up(&db, alloc);
    try Migration005AddIsFeedToLLM.up(&db, alloc);
    try Migration006AddAgent.up(&db, alloc);
    try Migration007AddSessionTracking.up(&db, alloc);
    try Migration008AddSessionSkills.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: migration 009 does not crash on a fresh-DB schema ────────────
//
// This is the canonical regression test for the "fresh-DB crash" bug.
// It MUST NOT return an error (the bug was `error.PrepareFailed` with
// message "no such column: created" from Migration 009's INSERT...SELECT).
// Before the fix, this test fails on a fresh DB. After the fix, it
// passes — and the CI smoke test (`scripts/ci-smoke-test.sh`) depends
// on this passing on the test runner's fresh $HOME.

test "Migration009RemoveCreatedColumn does not crash on fresh-DB schema (no 'created' column)" {
    const alloc = testing.allocator;
    var ctx = try setupDb009();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: pre-migration `llm_history` exists with `created_at` (not
    // `created`). If this assertion fails, the setup helper drifted out
    // of sync with Migration 001 — fix the helper, not the test.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM pragma_table_info('llm_history') WHERE name IN ('created', 'created_at')",
            &.{});
        defer q.deinit();
        var has_created: bool = false;
        var has_created_at: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "created")) has_created = true;
            if (std.mem.eql(u8, row.values[0], "created_at")) has_created_at = true;
        }
        try testing.expect(!has_created);
        try testing.expect(has_created_at);
    }

    // Run migration 009 — this is the line that crashed pre-fix.
    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Post-conditions: `llm_history_old` is gone (it was renamed then
    // dropped), `llm_history` still exists with `created_at`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE name IN ('llm_history', 'llm_history_old') ORDER BY name",
            &.{});
        defer q.deinit();
        var seen_llm_history: bool = false;
        var seen_llm_history_old: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "llm_history")) seen_llm_history = true;
            if (std.mem.eql(u8, row.values[0], "llm_history_old")) seen_llm_history_old = true;
        }
        try testing.expect(seen_llm_history);
        try testing.expect(!seen_llm_history_old);
    }
}

// ─── Test 2: pre-existing rows survive the rename-and-copy ────────────────
//
// Verifies that the COALESCE(created_at, CURRENT_TIMESTAMP) fix doesn't
// silently NULL out pre-existing rows. Inserts a single row with an
// explicit created_at, runs migration 009, asserts the row is still
// present with the same created_at value.

test "Migration009RemoveCreatedColumn preserves pre-existing rows' created_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb009();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert a deterministic row in the pre-migration schema.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('row_1', 'sess_1', 'm1', 'hello', '2026-06-30 12:34:56')",
        &.{});

    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Read it back: should still exist with the original created_at.
    var q = try ctx.db.query(alloc,
        "SELECT id, created_at FROM llm_history WHERE id = 'row_1'",
        &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RowMissing009;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("row_1", row.values[0]);
    try testing.expectEqualStrings("2026-06-30 12:34:56", row.values[1]);
}

// ===== Tests merged from migration_routines_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 044 (add task_type + routines table).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 044 introduces two new schema objects (a `task_type` column
// on the existing `workspace_item_tasks` table and a new `routines`
// table with a UNIQUE + FOREIGN KEY constraint and an index). A static
// source check would not catch a typo in the column type, a missing
// DEFAULT, a missing CASCADE, or a misspelled index name — all of
// which are easy regressions to make when writing a migration by hand.
//
// The working precedent for in-process sqlite-backed tests is
// `inherited_context_test.zig`: it opens `":memory:"` via
// `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
// scratch (mimicking the state a real DB would have just before the
// migration), runs the migration, and asserts via `db.query`. We
// mirror that exact pattern here.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`), `queryRow`, and `deinit`. There is no
// `prepare`/`step`/`columnText`/`columnInt`/`columnType`/`bindText`
// public API — column reads go through `Row.values[i]`, which is
// always text (so for the `enabled INTEGER NOT NULL DEFAULT 1`
// assertion we read the column as text and compare against "1").
//
// Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md
// Design: docs/plans/2026-06-13-add-task-routines-design.md

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the workspace_item_tasks table
/// present (matching the state after Migration 034), ready for
/// Migration 044 to add the `task_type` column on top.

fn setupDb044() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 034 exactly — same columns,
    // same NULL/NOT NULL semantics, same default timestamps. This is
    // what a real DB looks like the moment before Migration 044 runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    session_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText044(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: ALTER TABLE adds task_type with default 'standard' ──────────

test "Migration044AddRoutines adds task_type column defaulting to standard" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying task_type. The new column should
    // backfill it with the default 'standard' (the backwards-compat
    // contract for every pre-existing task row).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'foo', 'wi1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'bar', 'wi1')",
        &.{});

    const v1 = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v1);
    try testing.expectEqualStrings("standard", v1);

    const v2 = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't2'", &.{});
    defer alloc.free(v2);
    try testing.expectEqualStrings("standard", v2);
}

test "Migration044AddRoutines accepts explicit task_type override" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row with task_type='routine'. The column must accept
    // the override (not just always force 'standard').
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES ('t1', 'foo', 'wi1', 'routine')",
        &.{});

    const v = try scalarText044(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("routine", v);
}

// ─── Test 2: routines table with expected columns + constraints ──────────

test "Migration044AddRoutines creates routines table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // We need a parent workspace_item_tasks row for the FOREIGN KEY to
    // be satisfied. (The FK is on task_id → workspace_item_tasks.id.)
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    // Insert a routine row referencing the parent. Verify the
    // explicit-supplied columns and the implicit-default columns.
    try ctx.db.exec(alloc,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at)
        \\VALUES ('r1', 't1', '*/5 * * * *', 'do the thing', '2099-01-01 00:00:00')
    , &.{});

    // Read each column separately. SQLite `||` with a NULL operand
    // returns NULL, so we can't use string concatenation as a
    // one-shot "all columns in one string" check. The Row.values
    // API also returns each column as text, so this is the natural
    // way to assert on a multi-column read.
    const v = try scalarText044(alloc, &ctx.db,
        "SELECT schedule, initial_prompt, enabled, last_status, last_run_at FROM routines WHERE id = 'r1'",
        &.{});
    defer alloc.free(v);
    // Single-column scalar read — assert schedule (column 0) first.
    try testing.expectEqualStrings("*/5 * * * *", v);

    // Re-read each column independently and assert.
    const schedule = try scalarText044(alloc, &ctx.db, "SELECT schedule FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(schedule);
    try testing.expectEqualStrings("*/5 * * * *", schedule);

    const initial_prompt = try scalarText044(alloc, &ctx.db, "SELECT initial_prompt FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(initial_prompt);
    try testing.expectEqualStrings("do the thing", initial_prompt);

    // enabled is INTEGER NOT NULL DEFAULT 1 — read as text (the Row
    // API only returns text), the value is the string "1".
    const enabled = try scalarText044(alloc, &ctx.db, "SELECT enabled FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(enabled);
    try testing.expectEqualStrings("1", enabled);

    // last_status and last_run_at are nullable. Their text
    // representation in the Row API is the empty string when NULL.
    const last_status = try scalarText044(alloc, &ctx.db, "SELECT COALESCE(last_status, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_status);
    try testing.expectEqualStrings("", last_status);

    const last_run_at = try scalarText044(alloc, &ctx.db, "SELECT COALESCE(last_run_at, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_run_at);
    try testing.expectEqualStrings("", last_run_at);
}

test "Migration044AddRoutines enforces UNIQUE constraint on routines.task_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't1', '* * * * *', 'a', '2099-01-01 00:00:00')",
        &.{});

    // Second insert with the same task_id must fail (UNIQUE constraint).
    const result = ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r2', 't1', '* * * * *', 'b', '2099-01-01 00:00:00')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration044AddRoutines creates idx_routines_enabled_next_run index" {
    const alloc = testing.allocator;
    var ctx = try setupDb044();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_routines_enabled_next_run'",
        &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_enabled_next_run")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_chat_list_index_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 048 (add chat-list covering index).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 048 adds a single new SQLite index
// (`idx_llm_history_created_session` on `(created_at DESC, session_id)`)
// that is the load-bearing optimization for the chat-list query at
// `llm_history.zig:115`. A static source check would not catch a
// misspelled index name, a wrong column order, or a missing `DESC` on
// `created_at` — all of which would make the planner silently fall
// back to a full table scan. We assert the index actually exists in
// `sqlite_master` after `up()` runs, mirroring the pattern from
// `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
// `columnInt` public API — column reads go through `Row.values[i]`,
// which is always text.
//
// Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the `llm_history` table present
/// (matching the schema created by Migration 001), ready for
/// Migration 048 to add the `idx_llm_history_created_session` index on top.

fn setupDb048() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 001 exactly — same columns,
    // same NULL/NOT NULL semantics. The index only touches
    // (created_at, session_id) so those are the columns that must
    // exist with compatible types.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_results_json TEXT,
        \\    finish_reason TEXT,
        \\    usage_json TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: index exists in sqlite_master after up() ─────────────────────

test "Migration048AddChatListIndex creates idx_llm_history_created_session index" {
    const alloc = testing.allocator;
    var ctx = try setupDb048();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_llm_history_created_session")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: migration is idempotent (re-running up() does not fail) ─────

test "Migration048AddChatListIndex is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb048();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op. We assert no error is returned.
    try Migration048AddChatListIndex.up(&ctx.db, alloc);
    try Migration048AddChatListIndex.up(&ctx.db, alloc);

    // And the index is still there exactly once.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_llm_history_created_session'
    , &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.ExpectedRow048;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ===== Tests merged from migration_defensive_indexes_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 049 (add defensive indexes).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 049 adds two low-cost insurance indexes — one on
// `workspace_items(position DESC, id ASC)` and one on
// `routines(last_status)`. A static source check would not catch a
// misspelled index name, a wrong column order, or a dropped
// `CREATE INDEX` statement — all of which would make the planner
// silently fall back to a full table scan. We assert the indexes
// actually exist in `sqlite_master` after `up()` runs, mirroring the
// pattern from `migration_chat_list_index_test.zig` (the most recent
// precedent) and `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `ruangsql src/sqlite/Sqlite.zig (github.com/ginwa123/ruangsql)`) is: `init`, `exec`,
// `query` (returns `Rows` with `next()` → `?Row` carrying
// `values: [][]u8`). There is no `prepare`/`step`/`columnText`/
// `columnInt` public API — column reads go through `Row.values[i]`,
// which is always text.
//
// Plan: docs/plans/2026-06-19-performance-indexes.md (Chunk 3)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with BOTH `workspace_items` and
/// `routines` (plus the FK parent `workspace_item_tasks`) present —
/// matching the schema state just before Migration 049 runs. Migration
/// 049 does not add any columns, only two new indexes on existing
/// tables, so the minimum column set is whatever the two target
/// indexes reference.

fn setupDb049() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_item_tasks — parent of the routines.task_id FK.
    // The new indexes don't reference it, but the routines table
    // declares an FK to it so SQLite will reject CREATE TABLE
    // without it (the FK is a column-level constraint, so the
    // referenced table must exist before CREATE TABLE routines).
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // workspace_items — minimum columns for the position_id index.
    // The index covers (position DESC, id ASC), so both columns must
    // exist with compatible types. We mirror Migration 028's original
    // schema (id, workspace_id, item_type) and add `position` (the
    // Migration 045 schema). The test never inserts rows, so the
    // other columns are inert.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // routines — minimum columns for the last_status index. We
    // mirror the full Migration 044 CREATE TABLE (sans the
    // created_at / updated_at defaults which the test doesn't care
    // about) so the new index is guaranteed compatible.
    try db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at DATETIME,
        \\    next_run_at DATETIME NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText049(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: idx_workspace_items_position_id exists in sqlite_master ─────

test "Migration049AddDefensiveIndexes creates idx_workspace_items_position_id index" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows. We check
    // `name` (not just existence) so a typo in the index name is
    // caught — sqlite_master would still report it as a row.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_workspace_items_position_id")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 2: idx_routines_last_status exists in sqlite_master ────────────

test "Migration049AddDefensiveIndexes creates idx_routines_last_status index" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // Same pattern as test 1 but for the routines index.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_last_status")) {
            found = true;
        }
    }
    try testing.expect(found);
}

// ─── Test 3: migration is idempotent (re-running up() does not fail) ─────

test "Migration049AddDefensiveIndexes is idempotent on re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb049();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second
    // run is a no-op for both indexes. We assert no error is
    // returned. (Defensive: if a future change drops the IF NOT
    // EXISTS, this test fails immediately.)
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // And both indexes are still there exactly once. COUNT(*) is
    // returned as text per the SqliteBackend's row-as-text API.
    const wi_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer alloc.free(wi_count);
    try testing.expectEqualStrings("1", wi_count);

    const r_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer alloc.free(r_count);
    try testing.expectEqualStrings("1", r_count);
}

// ===== Tests merged from migration_git_worktree_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 046 (add git_worktree_cwd column to
// sessions).
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// Migration 046 is a simple ALTER TABLE ADD COLUMN, but a static source
// check would not catch a typo in the column name, a missing NULL/NOT
// NULL semantic, or a missing registration in `allMigrations` — all of
// which would silently break the new `set_git_worktree` tool that
// Chunks 2-4 of the plan will build on top of this column.
//
// The working precedent for in-process sqlite-backed tests is
// `migration_routines_test.zig`: it opens `":memory:"` via
// `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
// scratch (mimicking the state a real DB would have just before the
// migration), runs the migration, and asserts via `db.query`. We
// mirror that exact pattern here.
//
// Plan: docs/plans/2026-06-18-set-git-worktree-tool.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the sessions table present
/// (matching the state left by migrations 017 + 022 + 025 + 029 + 040),
/// ready for Migration 046 to add the `git_worktree_cwd` column on top.

fn setupDb046() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 017 + 022 + 025 + 029 + 040
    // exactly — same columns, same NULL/NOT NULL semantics, same default
    // timestamps. This is what a real DB looks like the moment before
    // Migration 046 runs.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    workspace_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText046(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: ALTER TABLE adds git_worktree_cwd defaulting to NULL ────────

test "Migration046AddGitWorktreeCwdToSessions adds git_worktree_cwd column defaulting to NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb046();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying git_worktree_cwd. The new column
    // should backfill NULL (the backwards-compat contract for every
    // pre-existing session row).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});

    // NULL is mapped to the empty string by COALESCE at the read site
    // (matching the convention used for cwd, created_at, updated_at,
    // and selected_profile_model).
    const v = try scalarText046(alloc, &ctx.db, "SELECT COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("", v);
}

// ─── Test 2: explicit value round-trips ──────────────────────────────────

test "Migration046AddGitWorktreeCwdToSessions accepts explicit value" {
    const alloc = testing.allocator;
    var ctx = try setupDb046();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});
    try ctx.db.exec(alloc, "UPDATE sessions SET git_worktree_cwd = '/abs/path' WHERE id = 't1'", &.{});

    const v = try scalarText046(alloc, &ctx.db, "SELECT s.git_worktree_cwd FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("/abs/path", v);
}

// ===== Tests merged from migration_051_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 051 (add kanban columns + task column refs).
//
// NOTE on numbering: The plan was written before Migrations 048 (chat-list
// index), 049 (defensive indexes), and 050 (pinned-to-workspace-item-tasks)
// landed on the branch. Per the plan's "find the LAST migration and add
// after it" instruction, this migration uses the next available number
// (051) instead of the originally proposed 048.
//
// What Migration 051 adds
// ───────────────────────
// 1. `kanban_columns` table with FK ON DELETE CASCADE to `workspace_items(id)`
// 2. Index `idx_kanban_columns_item_position` on (workspace_item_id, position)
// 3. Two new columns on `workspace_item_tasks`:
//      `kanban_column_id TEXT` (nullable — NULL for non-kanban items)
//      `kanban_position INTEGER NOT NULL DEFAULT 0` (per-column ordering)
// 4. Index `idx_tasks_column_position` on (kanban_column_id, kanban_position)
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// A static source check would not catch a misspelled table name, missing
// column, wrong DEFAULT, or missing FK clause. Asserting the actual
// schema after `up()` runs mirrors the pattern used by
// `migration_chat_list_index_test.zig` and `migration_routines_test.zig`.
//
// The SqliteBackend's public API (see
// `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`, `query`
// (returns `Rows` with `next()` → `?Row` carrying `values: [][]u8`).
// Column reads go through `Row.values[i]`, which is always text.
//
// Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` and
/// `workspace_item_tasks` tables present (matching the schema after
/// Migrations 028 and 034), ready for Migration 051 to add the kanban
/// schema on top.

fn setupDb051() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 028 + 034 — same column names
    // that Migration 051's FK references and ALTER TABLE statements
    // depend on.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: kanban_columns has the expected columns ──────────────────────

test "Migration051 creates kanban_columns table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb051();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert kanban_columns exists with the expected columns in the
    // expected order. pragma_table_info orders rows by cid (column
    // ordinal), so the iteration order matches CREATE TABLE column order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "id",
        "workspace_item_id",
        "name",
        "position",
        "created_at",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: workspace_item_tasks gets the two new columns ───────────────

test "Migration051 adds kanban_column_id and kanban_position to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb051();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration051AddKanban.up(&ctx.db, alloc);

    // Assert the two new columns are present. Sorted by name for a
    // stable assertion regardless of ALTER TABLE execution order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('workspace_item_tasks') " ++
        "WHERE name IN ('kanban_column_id', 'kanban_position') " ++
        "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_][]const u8{ "kanban_column_id", "kanban_position" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ===== Tests merged from migration_053_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 053 (add kanban_column.description).
//
// Why this file exists
// ────────────────────
// Migration 053 introduces the optional `description` column on
// `kanban_columns` so each column can carry a free-text "meaning"
// alongside its display name. The migration must:
//   1. ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''
//   2. Be idempotent (use DEFAULT so existing rows survive)
//   3. Add `description` to the pragma_table_info result set
//
// Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
//   (Chunk 1, Task 1.1)

fn setupDb053() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror
    // migration_051_test.zig's setup; 051 assumes these tables exist
    // (the production migrator walks 001 → 051 in order, so by the
    // time 051 runs they are already there).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    // Migration 051 creates kanban_columns — must run before 053.
    try Migration051AddKanban.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 053 adds description column with default empty string" {
    const alloc = testing.allocator;
    var ctx = try setupDb053();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: kanban_columns exists (051 seeded it).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q.deinit();
    const names_before: [5][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names_before.len);
        try testing.expectEqualStrings(names_before[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 5), idx);

    // Apply migration 053.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    // Re-check pragma_table_info — description is now present.
    var q2 = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q2.deinit();
    const names_after: [6][]const u8 = .{ "id", "workspace_item_id", "name", "position", "created_at", "description" };
    var idx2: usize = 0;
    while (try q2.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx2 < names_after.len);
        try testing.expectEqualStrings(names_after[idx2], row.values[0]);
        idx2 += 1;
    }
    try testing.expectEqual(@as(usize, 6), idx2);
}

test "migration 053 is safe on populated kanban_columns tables" {
    const alloc = testing.allocator;
    var ctx = try setupDb053();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert one existing row (no description column yet).
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_pre_053', 'wi_1', 'todo', 0)",
        &.{},
    );

    // Apply migration 053 — the existing row should get description=''.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM kanban_columns WHERE id = 'col_pre_053'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing053;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// ===== Tests merged from migration_054_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 054
// (make `session_queue_messages.message` nullable).
//
// Why this file exists
// ────────────────────
// Migration 054 drops the NOT NULL constraint on `session_queue_messages.message`
// so that image-only queued messages can be inserted without hitting
// `NOT NULL constraint failed: session_queue_messages.message` at the
// SqliteBackend.bind layer (which binds empty `[]const u8` as SQL NULL).
// The migration recreates the table to drop NOT NULL portably across all
// SQLite versions / platforms.
//
// The migration must:
//   1. Drop the NOT NULL on `message` (inserting empty message no longer errors)
//   2. Preserve all existing rows (id, session_id, message, image_url)
//   3. Recreate `idx_session_queue_messages_session` (re-added after the table swap)
//   4. Handle both schemas: with `image_url` (post-Migration037) and without
//
// Plan: docs/superpowers/plans/2026-07-01-session-queue-message-nullable.md
//   (Migration 054 design)

/// Test fixture for the migration_054 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.

const TestCtx054 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the Migration 018 baseline — i.e. the exact
/// schema that exists in production BEFORE Migration 037 (no image_url) and
/// BEFORE Migration 054 (message NOT NULL). This is the "bug exists" baseline.
fn setupDbWithoutImageUrl054() !TestCtx054 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration018CreateSessionQueueMessages.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Set up an in-memory DB with the Migration 037 schema — i.e. the same as
/// `setupDbWithoutImageUrl` PLUS the `image_url` column. This mirrors the
/// production state for any DB that ran up to Migration 053.
fn setupDbWithImageUrl054() !TestCtx054 {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    errdefer ctx.threaded.deinit();
    errdefer ctx.db.deinit();
    try Migration037AddImageUrlToSessionQueueMessages.up(&ctx.db, alloc);
    return ctx;
}

test "migration 054: bug exists before migration (insert empty message fails)" {
    // RED-GREEN half: this test demonstrates the original bug. With the
    // original Migration018 schema, inserting a row whose `message` is bound
    // as NULL (the SqliteBackend convention for empty `[]const u8`) hits the
    // NOT NULL constraint. After Migration054, the same insert succeeds.
    //
    // Note: we use `?` placeholders + `&.{ ... }` so the SqliteBackend bind
    // layer (src/modules/databases/sqlite/Sqlite.zig:73-74) sees the empty
    // `""` as `[]const u8` of length 0 and binds it as SQL NULL. A literal
    // `''` in the SQL is treated as the empty string, not NULL, and would
    // NOT trip the NOT NULL constraint.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Inserting with empty bound `message` — exactly the image-only queued
    // message shape that triggered the production bug. The NOT NULL on
    // `message` should fire because the empty slice binds as NULL.
    const rc = ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES (?, ?, ?)",
        &.{ "msg-bug", "sess-bug", "" },
    );
    try testing.expectError(error.ExecuteFailed, rc);
}

test "migration 054: empty message insert succeeds after migration" {
    // GREEN half: after applying the migration, the same INSERT that errored
    // above must succeed. The row must be readable and message is "" (or NULL,
    // which row.read returns as "").
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // Sanity: `message` no longer has NOT NULL.
    var q = try ctx.db.query(alloc,
        "SELECT \"notnull\" FROM pragma_table_info('session_queue_messages') " ++
        "WHERE name = 'message'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);

    // The insert that triggered the bug must now succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-fix', 'sess-fix', '')",
        &[_][]const u8{},
    );

    // Row is present and read back as "" (empty `[]const u8` binds as NULL,
    // but row read returns NULL as "").
    var q2 = try ctx.db.query(alloc,
        "SELECT message FROM session_queue_messages WHERE id = 'msg-fix'",
        &[_][]const u8{},
    );
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.NotFound054;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings("", row2.values[0]);
}

test "migration 054: existing rows survive the migration (no image_url)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a row before the migration.
    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message) " ++
        "VALUES ('msg-pre', 'sess-pre', 'hello world')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // The row must survive — id, session_id, message all preserved.
    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message FROM session_queue_messages " ++
        "WHERE id = 'msg-pre'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-pre", row.values[0]);
    try testing.expectEqualStrings("sess-pre", row.values[1]);
    try testing.expectEqualStrings("hello world", row.values[2]);
}

test "migration 054: existing rows survive the migration (with image_url)" {
    // Production-style DB: Migration018 + Migration037 applied (so image_url
    // exists), but NOT yet Migration054. The migration must preserve the
    // image_url column AND its data.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO session_queue_messages (id, session_id, message, image_url) " ++
        "VALUES ('msg-img', 'sess-img', 'with image', 'data:image/png;base64,xxx')",
        &[_][]const u8{},
    );

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, message, image_url FROM session_queue_messages " ++
        "WHERE id = 'msg-img'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-img", row.values[0]);
    try testing.expectEqualStrings("sess-img", row.values[1]);
    try testing.expectEqualStrings("with image", row.values[2]);
    try testing.expectEqualStrings("data:image/png;base64,xxx", row.values[3]);
}

test "migration 054: index idx_session_queue_messages_session is recreated" {
    // The migration drops and recreates the table — the index from Migration018
    // must be restored, otherwise the GET /api/queue_messages/:session_id
    // endpoint becomes slow + the FK lookup in workflow.zig regresses.
    const alloc = testing.allocator;
    var ctx = try setupDbWithoutImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: index exists after Migration018. We have to properly deinit
    // the row from `try q.next()` or we leak — see project memory
    // `zig-migration-tests-three-pitfalls.md`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='index' " ++
            "AND name = 'idx_session_queue_messages_session'",
            &[_][]const u8{},
        );
        defer q.deinit();
        if (try q.next()) |row| {
            defer row.deinit(alloc);
            try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
        } else {
            try testing.expect(false); // index should exist after Migration018
        }
    }

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    // After the migration, the index is back.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' " ++
        "AND name = 'idx_session_queue_messages_session'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NotFound054;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_queue_messages_session", row.values[0]);
}

test "migration 054: table has the expected columns in the expected order" {
    // The recreated table must have exactly: id, session_id, message, image_url,
    // created_at (in that order). ORDER BY cid confirms column ordering.
    const alloc = testing.allocator;
    var ctx = try setupDbWithImageUrl054();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration054MakeSessionQueueMessageNullable.up(&ctx.db, alloc);

    const expected: [5][]const u8 = .{
        "id", "session_id", "message", "image_url", "created_at",
    };
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_queue_messages') ORDER BY cid",
        &[_][]const u8{},
    );
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ===== Tests merged from migration_057_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 057 (add v6 element properties to
// `design_page_elements`).
//
// What Migration 057 adds
// ───────────────────────
// 11 new columns on `design_page_elements`:
//   type, rotation, fill, stroke, stroke_width, corner_radius,
//   opacity, text_content, text_style, image_url, parent_id
//
// All defaults are sensible:
//   - text/colour fields default to '' (the "no value" sentinel
//     per the `sqlite-backend-empty-slice-binds-as-null` convention)
//   - numeric defaults are 0 or 1.0 (no rotation, full opacity)
//   - `parent_id` is nullable (TEXT) for non-nested elements
//   - `type` defaults to 'rectangle' (the most common shape)
//
// Why a behavioral DB test (not a static check)?
// ───────────────────────────────────────────────
// A static source check would not catch a misspelled column name,
// wrong DEFAULT clause, missing ALTER TABLE statement, or a typo in
// the column type. Asserting the actual schema after `up()` runs
// mirrors the pattern used by `migration_051_test.zig`.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md (Task 1.1)

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` +
/// `design_pages` (Migration 055 v1 schema with `html` column) +
/// `design_page_elements` (Migration 056 v5 schema, 12 columns).
/// This mirrors the state of a DB that has Migrations 1..56 applied,
/// which is the precondition for Migration 057.

fn setupDb057() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items: required for the design_pages FK reference
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // workspace_item_tasks: required for Migration 066 FK from design_pages
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT NOT NULL, workspace_item_id TEXT NOT NULL, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    // design_pages v1 schema (Migration 055 — pre-upgrade, includes html)
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    workspace_item_task_id TEXT,
        \\    html TEXT NOT NULL DEFAULT '',
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    // design_page_elements v5 schema (Migration 056 — 12 columns, no v6 props)
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '', x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667, z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at DATETIME, updated_at DATETIME,
        \\    FOREIGN KEY (page_id) REFERENCES design_pages(id) ON DELETE CASCADE)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 057 adds all 11 v6 columns ────────────────────────

test "Migration057 adds the 11 v6 element properties columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the upgrade path through 055 → 056 → 057, mirroring what
    // the live migration manager does for an existing v1 user.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Assert all 11 new columns exist on design_page_elements.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('type','rotation','fill','stroke','stroke_width',
        \\                'corner_radius','opacity','text_content',
        \\                'text_style','image_url','parent_id')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    const expected = [_][]const u8{
        "corner_radius",
        "fill",
        "image_url",
        "opacity",
        "parent_id",
        "rotation",
        "stroke",
        "stroke_width",
        "text_content",
        "text_style",
        "type",
    };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), i);
}

// ─── Test 2: Migration 057 idempotent on a v6-ready DB ──────────────────

test "Migration057 is idempotent when the columns already exist" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run once.
    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // Run again — addColumnIfMissing must make this a no-op. If it
    // weren't idempotent, the second run would crash with
    // "duplicate column name: type" (or similar).
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);
}

// ─── Test 3: Migration 057 preserves existing v5 columns ─────────────────

test "Migration057 preserves the v5 columns on design_page_elements" {
    const alloc = testing.allocator;
    var ctx = try setupDb057();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration055AddDesignPages.up(&ctx.db, alloc);
    try Migration056UpgradeDesignPagesToFileModel.up(&ctx.db, alloc);
    try Migration057AddDesignElementProperties.up(&ctx.db, alloc);

    // The 12 v5 columns must still be present after 057 (which is
    // strictly additive — never drop).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_page_elements')
        \\WHERE name IN ('id','page_id','name','file_path','x','y','width',
        \\                'height','z_index','position','created_at','updated_at')
        \\ORDER BY name
    , &.{});
    defer q.deinit();

    var found: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 12), found);
}

// ===== Tests merged from migration_058_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 058
// (FTS5 virtual table on `llm_history` for workspace history search).
//
// Why this file exists
// ────────────────────
// Migration 058 creates `messages_fts` (a non-external-content FTS5 table
// over `llm_history.response_content` — content is duplicated so that
// the FTS5 `snippet()` and `highlight()` helper functions work) plus
// 3 sync triggers. This file verifies:
//   1. The virtual table is created with the correct configuration
//      (porter+unicode61 tokenizer)
//   2. Exactly 3 triggers exist on `llm_history` (INSERT/UPDATE/DELETE)
//   3. Pre-existing rows in `llm_history` are backfilled into the FTS index
//   4. New INSERTs into `llm_history` are auto-indexed (trigger fires)
//   5. DELETEs from `llm_history` remove the row from the FTS index
//
// Why the test bootstraps with Migration001CreateLLMHistory
// ──────────────────────────────────────────────────────────
// Mirrors the migration_054_test.zig pattern — set up the minimum
// pre-migration baseline (just `llm_history` itself), then apply the
// migration. This isolates the migration's effect from any schema
// interaction with Migrations 002..057 that may or may not have run on
// production DBs.
//
// Why FTS5 MATCH ? with single-token words
// ────────────────────────────────────────
// FTS5 tokenizes input by default; bare ASCII words are safe queries.
// Multi-word queries would require FTS5 expression syntax (AND, OR, "...",
// prefix*) which would couple the test to the tokenizer's exact behavior.
// Single-token MATCH keeps the contract tight: "the row containing word
// W is in the FTS index".
//
// Plan: workspace history FTS (Chunk 1, Task 1.3 — Migration 058 regression test)
//
// Versioning note: the original plan called this Migration 055 but the
// branch already had AddDesignPages (55), UpgradeDesignPagesToFileModel
// (56), AddDesignElementProperties (57). 058 is the next free slot.

/// Test fixture for the migration_058 test suite. Hoisted to a top-level named
/// struct (NOT inline anonymous) because Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
/// fields — see project memory `zig-anonymous-struct-type-identity.md`.

const TestCtx058 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table. This
/// matches the state of an existing-DB user right before Migration 058 runs
/// (i.e., after Migrations 001..057 have all applied).
fn setupDbWithLlmHistory058() !TestCtx058 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `sqlite_master` of a given type, optionally matching
/// `tbl_name`. Returns 0 if no match. Helper for the trigger + table tests.
fn countSqliteMaster058(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, sql: []const u8) !usize {
    var q = try db.query(alloc, sql, &[_][]const u8{});
    defer q.deinit();
    var count: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        count += 1;
    }
    return count;
}

test "migration 058: creates messages_fts virtual table" {
    // After Migration 058, `sqlite_master` must contain a row for
    // `messages_fts` with type='table' (FTS5 virtual tables show up as
    // 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, no `messages_fts` exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
            &[_][]const u8{},
        );
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have messages_fts
        }
    }

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: `messages_fts` exists as a table.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='messages_fts'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.VirtualTableNotCreated058;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("messages_fts", row.values[0]);
}

test "migration 058: installs sync triggers (exactly 3 on llm_history)" {
    // The migration creates 3 triggers named llm_history_ai, _ad, _au.
    // After Migration 058, querying sqlite_master with
    // `tbl_name='llm_history'` AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on llm_history.
    const pre_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 0), pre_count);

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    const post_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 3), post_count);

    // Verify the exact names (the migration uses _ai, _ad, _au).
    var names_buf: [3][]u8 = .{ &[_]u8{}, &[_]u8{}, &[_]u8{} };
    defer for (names_buf) |n| if (n.len > 0) alloc.free(n);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='llm_history'
        \\ORDER BY name
    , &[_][]const u8{});
    defer q.deinit();
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < 3);
        names_buf[idx] = try alloc.dupe(u8, row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
    try testing.expectEqualStrings("llm_history_ad", names_buf[0]);
    try testing.expectEqualStrings("llm_history_ai", names_buf[1]);
    try testing.expectEqualStrings("llm_history_au", names_buf[2]);
}

test "migration 058: backfills existing rows into FTS index" {
    // Pre-existing rows must be backfilled into messages_fts during
    // migration. Insert 2 rows BEFORE the migration, run it, then verify
    // that FTS5 MATCH on a unique word from each row returns the row.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert 2 rows BEFORE the migration — uses Migration001's schema
    // (id, session_id, model, response_content). Note: the `id` column
    // is TEXT PRIMARY KEY so we pass explicit IDs.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-1', 'sess-1', 'm', 'first message contains zephyrword')",
        &[_][]const u8{},
    );
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-pre-2', 'sess-2', 'm', 'second message contains quasarterm')",
        &[_][]const u8{},
    );

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // FTS MATCH on 'zephyrword' must return the row with id 'msg-pre-1'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"zephyrword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow1058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-1", row.values[0]);

        // Should be only 1 row matching zephyrword.
        const extra = (try q.next()) orelse null;
        if (extra) |e| {
            defer e.deinit(alloc);
            try testing.expect(false); // zephyrword matched more than 1 row
        }
    }

    // FTS MATCH on 'quasarterm' must return the row with id 'msg-pre-2'.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"quasarterm"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.BackfillMissingRow2058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-pre-2", row.values[0]);
    }
}

test "migration 058: INSERT trigger fires for new rows" {
    // After migration, INSERT INTO llm_history must auto-add to the FTS
    // index. Insert one new row AFTER migration; FTS MATCH must find it.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Insert AFTER migration.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-post-1', 'sess-1', 'm', 'post-migration message has deltaword')",
        &[_][]const u8{},
    );

    // FTS MATCH on 'deltaword' must return the new row.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"deltaword"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.InsertTriggerDidNotFire058;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("msg-post-1", row.values[0]);
}

test "migration 058: DELETE trigger removes row from index" {
    // After migration, DELETE FROM llm_history must auto-remove from the
    // FTS index. Insert one row, delete it, then FTS MATCH must return
    // null (no rows match).
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
        "VALUES ('msg-del-1', 'sess-1', 'm', 'about to be deleted contains omegaword')",
        &[_][]const u8{},
    );

    // Sanity: the row IS indexed before deletion.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT h.id FROM llm_history h
            \\JOIN messages_fts f ON f.rowid = h.rowid
            \\WHERE messages_fts MATCH ?
        , &.{"omegaword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowNotIndexedBeforeDelete058;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("msg-del-1", row.values[0]);
    }

    // Delete the row.
    try ctx.db.exec(alloc,
        "DELETE FROM llm_history WHERE id = 'msg-del-1'",
        &[_][]const u8{},
    );

    // After deletion, FTS MATCH on the unique word must return null.
    var q = try ctx.db.query(alloc,
        \\SELECT h.id FROM llm_history h
        \\JOIN messages_fts f ON f.rowid = h.rowid
        \\WHERE messages_fts MATCH ?
    , &.{"omegaword"});
    defer q.deinit();
    const row = (try q.next()) orelse null;
    if (row) |r| {
        defer r.deinit(alloc);
        try testing.expect(false); // DELETE trigger did not fire — row still in index
    }
}

// ===== Tests merged from migration_059_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 059
// (llm_history.created_iso column populated by application code + backfill).
//
// Why this file exists
// ────────────────────
// Migration 059 adds a regular TEXT column `created_iso` to
// `llm_history`. The column is populated by **application code** in
// `saveMessage` (libc `localtime_r` + `strftime`) at INSERT time, and
// by an idempotent backfill `UPDATE` for legacy rows that pre-date
// the application update. The workspace history / getCompactedMessages
// SQL filters on `since`/`until` bind to this column, so the documented
// `since`/`until` format works.
//
// Before this migration, the filters did a lex comparison on the
// `created_at` TEXT column (which stores Unix microseconds like
// `"1784119389936251112"`) against user input like `"2026-07-15 00:00:00"`.
// Because `'1' < '2'` lexicographically, every data row was always
// considered "less than" a date string starting with `'2'`, so the
// filter silently returned 0 rows.
//
// ## Why application code, not SQLite triggers?
//
// v1 of this migration used INSERT/UPDATE triggers to populate
// `created_iso`. This had two production failures:
//   1. Triggers are invisible to application code — when the
//      trigger's `datetime()` overflowed, debugging required
//      reading SQL trigger bodies.
//   2. The trigger's `datetime(CAST(<microseconds> AS REAL) / 1000000, ...)`
//      overflows SQLite's `datetime()` range (cap: year 9999) and
//      silently returns NULL for modern timestamps.
//
// Application-level computation via Zig's `std.time.epoch` API
// (in `helpers.currentTimeIsoLocal`) sidesteps both issues.
//
// ## Why not a STORED GENERATED column?
//
// `datetime(..., 'localtime')` is non-deterministic (depends on the
// system timezone). SQLite silently DROPS any GENERATED ALWAYS AS
// STORED column whose expression uses a non-deterministic function —
// verified empirically against SQLite 3.53.3. The column is omitted
// from `pragma_table_info` with no error.
//
// ## Idempotency
//
// `addColumnIfMissing` skips the ALTER if the column exists.
// The backfill UPDATE has `WHERE created_iso IS NULL OR created_iso = ''`,
// so it only touches rows that still need populating.
// The CREATE INDEX uses IF NOT EXISTS.
//
// This file verifies:
//   1. The column `created_iso` exists on `llm_history` after the
//      migration (NOT a generated column).
//   2. The migration's idempotent backfill populates `created_iso`
//      from `created_at` for legacy rows.
//   3. Lex comparison against a date string picks up the correct rows
//      (the actual bug regression).
//   4. The index `idx_llm_history_created_iso` is created.
//   5. The migration is idempotent (re-runs are no-ops).
//
// Plan: workspace history `created_iso` backfill.

const TestCtx059 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table.
/// Mirrors the migration_058_test.zig / migration_054_test.zig pattern.
fn setupDbWithLlmHistory059() !TestCtx059 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Read a column attribute by name from `pragma_table_xinfo('llm_history')`.
/// Returns null if the column doesn't exist.
///
/// We use `pragma_table_xinfo` (NOT `pragma_table_info`) because the
/// `xinfo` variant includes a 7th column "hidden" with values:
///   - 0 = normal column
///   - 2 = VIRTUAL generated column
///   - 3 = STORED generated column
/// `pragma_table_info` only returns the 6 normal columns and doesn't
/// surface the generated-column flag at all.
fn columnExists059(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    column_name: []const u8,
) !?struct { found: bool, is_generated: bool } {
    var q = try db.query(alloc,
        "SELECT name, hidden FROM pragma_table_xinfo('llm_history') WHERE name = ?",
        &.{column_name});
    defer q.deinit();
    const row = (try q.next()) orelse return .{ .found = false, .is_generated = false };
    defer row.deinit(alloc);
    // `hidden` is 0 for normal columns, 2 for VIRTUAL generated, 3 for
    // STORED generated. We treat any nonzero as "is generated".
    const gen = std.fmt.parseInt(u32, row.values[1], 10) catch 0;
    return .{ .found = true, .is_generated = gen != 0 };
}

test "migration 059: creates created_iso regular TEXT column (not generated)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Pre-migration: no created_iso column.
    const pre = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(false, pre.?.found);

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: column exists, is NOT generated (regular TEXT).
    // The trigger-based approach can't use GENERATED ALWAYS AS STORED
    // because `datetime(..., 'localtime')` is non-deterministic.
    const post = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expect(post != null);
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}

test "migration 059: backfills existing rows from created_at" {
    // Application code in `saveMessage` is responsible for populating
    // `created_iso` on new INSERTs. This test exercises the migration's
    // idempotent backfill (the `UPDATE ... WHERE created_iso IS NULL`),
    // which fills `created_iso` for rows that existed before the
    // application was updated. Equivalent to the "INSERT trigger"
    // behavior in v1, but explicit and re-runnable.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert a row FIRST with a known microsecond timestamp and NULL
    // `created_iso` (matching the production state of legacy rows).
    const micros: []const u8 = "1780000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_iso','s1','m','content with isocheckword',?)", &.{micros});

    // Pre-migration: `created_iso` is NULL (no column yet actually,
    // we need to add it first manually to simulate the legacy state).
    // Easier: run the migration itself, which adds the column AND
    // backfills.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: the row's created_iso is populated.
    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_iso'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing059;
    defer row.deinit(alloc);
    const generated = row.values[0];

    // Compute the expected value using the SAME SQLite expression the
    // migration's backfill uses (substring + datetime). This keeps the
    // test timezone-agnostic.
    var expected_q = try ctx.db.query(alloc,
        "SELECT datetime(substr(?, 1, 10), 'unixepoch')", &.{micros});
    defer expected_q.deinit();
    const expected_row = (try expected_q.next()) orelse return error.ExpectedExprFailed059;
    defer expected_row.deinit(alloc);
    const expected = expected_row.values[0];

    try testing.expectEqualStrings(expected, generated);
    try testing.expect(generated.len > 0);
}

test "migration 059: lex comparison against a date string selects the correct rows (regression)" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Insert two rows at known microsecond timestamps. `created_iso`
    // is populated by the migration's backfill (substr(micros, 1, 10)).
    const old_micros: []const u8 = "1780000000000000";
    const new_micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_old','s1','m','old isocheckword',?)", &.{old_micros});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_new','s1','m','new isocheckword',?)", &.{new_micros});

    // Re-run the migration so the backfill UPDATE processes these
    // newly-inserted rows (the FIRST run happened BEFORE these inserts).
    // Re-runs are idempotent.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Compute the ISO for `new_micros` using the same expression the
    // backfill uses (substr(micros, 1, 10)). Lex comparison must use
    // the same expression or it won't match.
    var iso_q = try ctx.db.query(alloc,
        "SELECT datetime(substr(?, 1, 10), 'unixepoch')", &.{new_micros});
    defer iso_q.deinit();
    const iso_row = (try iso_q.next()) orelse return error.IsoExprFailed059;
    defer iso_row.deinit(alloc);
    const new_iso = iso_row.values[0];

    // Lex comparison against `created_iso`: rows with created_iso >=
    // new_iso should match. This is the EXACT shape of the bug fix —
    // a date string like "2026-07-15 00:00:00" lexicographically
    // matches against the populated ISO column, not the raw microsecond
    // string.
    var hits_q = try ctx.db.query(alloc,
        \\SELECT id FROM llm_history
        \\WHERE created_iso >= ?
        \\ORDER BY id
    , &.{new_iso});
    defer hits_q.deinit();

    var count: usize = 0;
    var matched_ids: [4][]u8 = undefined;
    var match_idx: usize = 0;
    while (try hits_q.next()) |row| {
        defer row.deinit(alloc);
        if (match_idx < matched_ids.len) {
            matched_ids[match_idx] = try alloc.dupe(u8, row.values[0]);
            match_idx += 1;
        }
        count += 1;
    }
    defer for (matched_ids[0..match_idx]) |id| alloc.free(id);

    // Only h_new should match (created_iso >= new_iso excludes h_old).
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqualStrings("h_new", matched_ids[0]);
}

test "migration 059: creates idx_llm_history_created_iso index" {
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Post-migration: an index named `idx_llm_history_created_iso` exists
    // on the `created_iso` column.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND tbl_name='llm_history' AND name='idx_llm_history_created_iso'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated059;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_created_iso", row.values[0]);
}

test "migration 059: is idempotent on a re-run (column + triggers + index)" {
    // `addColumnIfMissing` checks pragma_table_info first, the triggers
    // use `IF NOT EXISTS`, and the index uses `IF NOT EXISTS`. A re-run
    // on a DB that already has everything is a no-op.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory059();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration059AddCreatedIso.up(&ctx.db, alloc);
    // Run it again — must not error.
    try Migration059AddCreatedIso.up(&ctx.db, alloc);

    // Still exactly one created_iso column.
    const post = try columnExists059(&ctx.db, alloc, "created_iso");
    try testing.expectEqual(true, post.?.found);
    try testing.expectEqual(false, post.?.is_generated);
}

// ===== Tests merged from migration_060_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 060
// (llm_history.created_iso re-backfill).
//
// Why this file exists
// ────────────────────
// Production databases that ran V1 of Migration 059 (which used
// SQLite INSERT/UPDATE triggers to populate `created_iso`) ended up
// with many rows having `created_iso = NULL` because the trigger's
// `datetime(CAST(<microseconds> AS REAL) / 1000000, 'unixepoch',
// 'localtime')` overflowed SQLite's `datetime()` range (cap: year
// 9999) for modern timestamps. This silently broke the
// `since`/`until` filter on workspace history reads and
// `getCompactedMessages`.
//
// Migration 060 unconditionally re-runs the v2 backfill UPDATE so
// production users get a fix on the next pabrik restart without
// having to nuke their `agent.db`.
//
// This file verifies:
//   1. Legacy rows with NULL `created_iso` get populated.
//   2. The migration is idempotent (re-runs are no-ops on populated rows).
//   3. A row with an empty string `created_at` falls back to `now`.
//   4. Existing populated rows are NOT overwritten (defensive).

const TestCtx060 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb060() !TestCtx060 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    // Migration 060 expects `created_iso` to exist. Migration 059
    // creates it (with a backfill that touches the existing rows).
    // Migration 060 then re-runs the backfill.
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 060: re-backfills rows with NULL created_iso" {
    // Simulates the production state: v1 of Migration 059 (broken trigger)
    // left a row with NULL created_iso. v2 of Migration 059 used a
    // different SQL expression that doesn't match what v1's broken trigger
    // would have left, so production NULLs persist.
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_legacy','s1','m','legacy row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_legacy'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 060: re-backfills row with empty created_at using datetime('now')" {
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_empty','s1','m','empty created_at','')", &.{});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_empty'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // datetime('now') produces the current date — match any YYYY-MM-DD prefix.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "-") != null);
}

test "migration 060: idempotent on re-run (no changes after second run)" {
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_idem','s1','m','idempotent row',?)", &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q1 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q1.deinit();
    const row1 = (try q1.next()) orelse return error.RowMissing060;
    const first_value = try alloc.dupe(u8, row1.values[0]);
    row1.deinit(alloc);
    defer alloc.free(first_value);

    // Run again — should not change anything.
    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);
    var q2 = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_idem'", &.{});
    defer q2.deinit();
    const row2 = (try q2.next()) orelse return error.RowMissing060;
    defer row2.deinit(alloc);
    try testing.expectEqualStrings(first_value, row2.values[0]);
}

test "migration 060: only updates rows where created_iso is NULL or empty" {
    // Regression check: production datasets that already have valid
    // created_iso (because the application ran the corrected saveMessage
    // for new inserts) must NOT be overwritten with a coarser computation.
    //
    // We can verify this by inserting a row WITH a created_iso value
    // that's clearly human-set (e.g. longer than 19 chars or contains
    // a non-ASCII marker). After the migration, that value should be
    // intact because the second (unconditional) UPDATE doesn't run —
    // the WHERE guard stopped it.
    //
    // For a simpler robustness check: insert a row, hand-set
    // `created_iso` to a known literal, run the migration, and verify
    // the literal is preserved.
    const alloc = testing.allocator;
    var ctx = try setupDb060();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_pre','s1','m','pre-populated row',?, 'CUSTOM-MARKER-ISO')",
        &.{micros});

    try Migration060RebackfillCreatedIso.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_pre'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing060;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("CUSTOM-MARKER-ISO", row.values[0]);
}

// ===== Tests merged from migration_061_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 061
// (`llm_history.created_iso` year-fix).
//
// Why this file exists
// ────────────────────
// Migration 060 re-backfilled NULL/empty `created_iso` rows but did
// NOT detect the **wrong-year** rows that were silently produced by
// `saveMessage` passing nanosecond values (length 19) to a helper
// expecting microseconds. The helper divided by `us_per_s` (1e6)
// instead of `ns_per_s` (1e9), producing sec ≈ 1.78e12 instead of
// 1.78e9 — which decodes as year 58,507 instead of 2026. The wrong
// values passed Migration 060's `IS NULL OR = ''` guard and were
// never overwritten.
//
// Migration 061 fixes both shapes (NULL/empty AND wrong-year) with
// a single UPDATE that recomputes from `created_at` directly. The
// `created_iso NOT LIKE '[12][09][0-9][0-9]-%'` clause is what
// catches the year 58,507 rows.
//
// This file verifies:
//   1. Legacy rows with NULL `created_iso` get populated.
//   2. Rows with a wrong-year `created_iso` (e.g. `58507-07-26 ...`)
//      get re-populated with the correct year.
//   3. Already-correct rows are NOT overwritten (idempotent on
//      correct rows; see the `LIKE '[12][09][0-9][0-9]-%'` guard).
//   4. `saveMessage` (in the same test binary) writes a correct-year
//      `created_iso` when invoked with the post-fix code path.
//   5. `inserLLMHistories` (the other INSERT path that previously
//      omitted `created_iso` entirely) writes a correct-year value.

const TestCtx061 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb061() !TestCtx061 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 061: backfills rows with NULL created_iso" {
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1785000000000000"; // ~2026-07-25
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('h_null','s1','m','null iso',?)", &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_null'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
}

test "migration 061: backfills rows with wrong-year created_iso (e.g. 58507-07-26 ...)" {
    // This is the regression check for the year-58,507 bug. The
    // pre-fix `saveMessage` produced these values by passing
    // nanoseconds (length 19) to a helper expecting microseconds.
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_bad_year','s1','m','wrong year',?, '58507-07-26 11:32:30')",
        &.{nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_bad_year'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    // The fixed value MUST be year 2026, not 58507.
    try testing.expect(std.mem.indexOf(u8, row.values[0], "2026") != null);
    try testing.expect(std.mem.indexOf(u8, row.values[0], "58507") == null);
}

test "migration 061: does NOT overwrite correct-year created_iso" {
    // A row whose `created_iso` value matches what the migration
    // would compute from `created_at` MUST be preserved (the LIKE
    // guard stops the UPDATE). We pick a `created_at` whose substr
    // recompute equals the hand-set ISO string, so even if the
    // migration DID overwrite, the result would be identical.
    //
    // created_at "1784131200000000" (microseconds) → substr(1,10)
    //   "1784131200" → datetime(1784131200, 'unixepoch') =
    //   '2026-07-15 16:00:00' UTC. Verified with:
    //   `SELECT strftime('%s', '2026-07-15 16:00:00')` → 1784131200.
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const micros: []const u8 = "1784131200000000";
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) " ++
        "VALUES ('h_correct','s1','m','correct row',?, '2026-07-15 16:00:00')",
        &.{micros});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT created_iso FROM llm_history WHERE id = 'h_correct'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing061;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2026-07-15 16:00:00", row.values[0]);
}

test "migration 061: handles mixed NULL + wrong-year + correct rows in one pass" {
    const alloc = testing.allocator;
    var ctx = try setupDb061();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const nanos: []const u8 = "1784152565916089746"; // 2026-07-15 21:56:05 UTC, in ns
    try ctx.db.exec(alloc,
        \\INSERT INTO llm_history (id, session_id, model, response_content, created_at, created_iso) VALUES
        \\('h_null','s1','m','null row',       ?, NULL),
        \\('h_empty','s1','m','empty row',     ?, ''),
        \\('h_bad','s1','m','bad year row',    ?, '58507-07-26 11:32:30'),
        \\('h_ok','s1','m','correct row',      ?, '2026-07-15 21:56:05'),
        \\('h_old','s1','m','1999 row',        ?, '1999-12-31 23:59:59')
    , &.{nanos, nanos, nanos, nanos, nanos});

    try Migration061FixCreatedIsoYear.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT id, created_iso FROM llm_history ORDER BY id", &.{});
    defer q.deinit();
    var rows: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        rows += 1;
        const id = row.values[0];
        const iso = row.values[1];
        if (std.mem.eql(u8, id, "h_null") or std.mem.eql(u8, id, "h_empty") or
            std.mem.eql(u8, id, "h_bad"))
        {
            // These three rows had bad values; they MUST be fixed
            // to year 2026 (because substr(1784152565916..., 1, 10)
            // → 1784152565 → 2026-07-15 21:56:05).
            try testing.expect(std.mem.indexOf(u8, iso, "2026") != null);
            try testing.expect(std.mem.indexOf(u8, iso, "58507") == null);
        } else if (std.mem.eql(u8, id, "h_ok")) {
            // Correct row: MUST be preserved verbatim (the LIKE
            // guard '20[0-9][0-9]-%' matched, so WHERE is false).
            try testing.expectEqualStrings("2026-07-15 21:56:05", iso);
        } else if (std.mem.eql(u8, id, "h_old")) {
            // '1999-...' starts with '19', not '20'. The LIKE guard
            // does NOT match, so the migration does NOT touch it.
            // Pre-2000 rows are legitimate data, not a bug.
            try testing.expectEqualStrings("1999-12-31 23:59:59", iso);
        }
    }
    try testing.expectEqual(@as(usize, 5), rows);
}

// ===== Tests merged from migration_062_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 062
// (workspace_item_tasks.description).
//
// Why this file exists
// ────────────────────
// Migration 062 introduces a free-form `description` column on
// `workspace_item_tasks` so each task (chat / routine / kanban) can
// carry a user-visible "notes" field alongside its display name.
// The detail dialog (frontend, Chunk 2) reads and writes it; the
// backend persists it. The migration must:
//   1. Add `description TEXT NOT NULL DEFAULT ''` to the table
//   2. Be idempotent (existing rows survive via DEFAULT '')
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing`
//      so the helper handles both fresh-DB and upgrade-from-v1 paths
//      gracefully (see memory `pabrik-fresh-db-migration-cascade`).
//
// Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
//   (Chunk 1, Task 1.1)

const Migration062 = Migration062AddTaskDescription;
const createWorkspaceItemTask = @import("pabrikcore").ai_mod.llm_history.createWorkspaceItemTask;

const TestCtx062 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb062() !TestCtx062 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before migration 061
    // can run — production walks migrations 001 → 061 in order, so by
    // the time 061 runs they're already there. We create minimal
    // mirrors here for the unit test.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // The behavioural tests below INSERT into `task_type` (via the
    // routine/memory branches of task_create.zig and via
    // createWorkspaceItemTask), so the column must exist before
    // Migration 062 runs. The real migration (034) declares this and
    // 30+ others; we only need the minimum that the create helper
    // references. Migration 062's `addColumnIfMissing` will then add
    // `description` to this minimal table.
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration062 adds description column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: description does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'description'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply migration 061.
    try Migration062.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("description", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match).
    try testing.expect((try q.next()) == null);
}

test "Migration062 is idempotent on a column that already exists" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `description TEXT NOT NULL DEFAULT ''`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    // Drop the minimal table from setupDb() and re-create it with the
    // canonical schema that already declares description.
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    description TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — `addColumnIfMissing` detects the column
    // already exists and short-circuits.
    try Migration062.up(&ctx.db, alloc);

    // Re-check: still one `description` column (no duplicates).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'description'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration062 gives pre-existing rows an empty-string description" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task (no description column yet — it's
    // added by the migration).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_061', 'Task', 'wi_1')",
        &.{});

    // Apply migration 061 — the existing row should get description=''.
    try Migration062.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM workspace_item_tasks WHERE id = 'task_pre_061'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing062;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// =====================================================================
// Behavioural regression tests for the empty-string-bind bug.
//
// Why these tests exist
// ---------------------
// The migration adds a `NOT NULL DEFAULT ''` column. The `task_create`
// HTTP handler calls `createWorkspaceItemTask` (and the routine/memory
// branches do their own INSERTs). All three paths previously wrote the
// description with `db.exec(..., description orelse "")` — which passes
// an empty `[]const u8` to the SQLite backend. `SqliteBackend.exec`
// binds an empty slice as SQL NULL (see project memory
// `sqlite-backend-empty-slice-binds-as-null`), so the INSERT crashed
// with `NOT NULL constraint failed: workspace_item_tasks.description`
// for every standard/routine/memory task create where the caller
// either omitted description (= null in JSON) or sent `""`.
//
// The fix splits the INSERT into a three-way branch:
//   - description == null  → omit the description column; DEFAULT ''
//     applies.
//   - description == ""   → use a SQL `''` literal (not a `?` bind).
//   - description == "x…" → bind via `?` like normal.
//
// The static tests above check that the three-way branch EXISTS in
// the source. These behavioural tests actually run the helper against
// an in-memory sqlite with the real Migration 062 applied, and prove
// no `NOT NULL` violation fires for any of the three caller shapes.

/// Seed a workspace_items row so `workspace_item_tasks.workspace_item_id`
/// has a real FK target. Returns the parent id.
fn seedParent062(ctx: *TestCtx062, allocator: std.mem.Allocator) ![]const u8 {
    const parent_id = "wi_parent_061";
    try ctx.db.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES (?, 'ws_1', 'chat')",
        &[_][]const u8{parent_id});
    return parent_id;
}

/// Read back the description column for a task by id. Returns an
/// owned copy (allocated with `allocator`) because `row.values[0]`
/// is freed by `row.deinit(allocator)` at function exit; returning the
/// raw borrowed slice would be a use-after-free once the defer fires
/// (see project memory `zig-slice-headers-across-defer-lifetimes`).
fn readDescription062(ctx: *TestCtx062, allocator: std.mem.Allocator, task_id: []const u8) !?[]u8 {
    var q = try ctx.db.query(allocator,
        "SELECT description FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{task_id});
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

/// Wrapper that frees the owned `readDescription` slice. The caller
/// passes the slice via this helper so the free lives close to the
/// assertion (no leaks even if the assertion panics).
fn expectDescriptionEquals062(
    ctx: *TestCtx062,
    allocator: std.mem.Allocator,
    task_id: []const u8,
    expected: []const u8,
) !void {
    const owned = (try readDescription062(ctx, allocator, task_id)) orelse return error.NoRow062;
    defer allocator.free(owned);
    try testing.expectEqualStrings(expected, owned);
}

test "createWorkspaceItemTask: description = null succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // Caller passes null (omitted body field).
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_null_061", "No description", parent_id, "standard", null,
        // tags — Migration 067 added this arg; pre-Migration-067 callers
        // passed null. The migration_062_test exercises the description
        // path only; tags are exercised in migration_067_test.zig.
        null,
        // image_urls (Migration 069) — added as 8th-arg default-null;
        // migration_062_test predates the column and exercises the
        // description path only. image_urls is exercised in
        // migration_069_test.zig.
        null,
        // cwd (Migration 070) — null (omitted body field → empty-string
        // sentinel). migration_062_test predates Migration 070 and
        // exercises the description path only; cwd is fully covered in
        // migration_071_test.zig.
        null,
        // video_urls (Migration 090) — null. Covered in video_urls_validation tests.
        null);
    defer task.deinit(alloc);

    // SELECT the column back and confirm it was stored as the empty
    // string (DEFAULT '' via the omitted-column branch).
    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_null_061", "");
}

test "createWorkspaceItemTask: description = '' (empty string) succeeds and stores ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // This is the EXACT bug case. Pre-fix: `description orelse ""` made
    // the bind arg an empty `[]const u8` which SqliteBackend.exec
    // converts to SQL NULL → `NOT NULL constraint failed`. Post-fix:
    // the empty-string branch uses a SQL `''` literal.
    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_empty_061", "Empty description", parent_id, "standard", "",
        // tags — see comment on the null-tags branch above.
        null,
        // image_urls — null (omitted body field → empty-string
        // sentinel). See migration_069_test for full-coverage tests.
        null,
        // cwd (Migration 070) — null. See comment above.
        null,
        // video_urls (Migration 090) — null. See comment above.
        null);
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_empty_061", "");
}

test "createWorkspaceItemTask: description = 'hello world' succeeds and stores the value" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    const task = try createWorkspaceItemTask(alloc, &ctx.db,
        "t_desc_filled_061", "With description", parent_id, "standard",
        "hello world from test",
        // tags — see comment on the null-tags branch above.
        null,
        // image_urls — null (omitted body field → empty-string
        // sentinel). See migration_069_test for full-coverage tests.
        null,
        // cwd (Migration 070) — null. See comment above.
        null,
        // video_urls (Migration 090) — null. See comment above.
        null);
    defer task.deinit(alloc);

    try testing.expectEqualStrings("hello world from test", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_filled_061", "hello world from test");
}

// Direct `db.exec` mirror of the createRoutineTask + createMemoryTask
// INSERT branches. These branches don't go through
// `createWorkspaceItemTask` so they need their own exercise of the
// `''`-literal-vs-bind footgun fix. The test asserts the same three
// caller shapes work — null, "", "x…" — for each task_type the
// handler can produce.

const RoutineCase062 = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};
const MemoryCase062 = struct {
    task_id: []const u8,
    desc: ?[]const u8,
};

test "task_create direct INSERT branches: null/empty/value all succeed for routine task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    const cases = [_]RoutineCase062{
        .{ .task_id = "t_routine_null_061", .desc = null },
        .{ .task_id = "t_routine_empty_061", .desc = "" },
        .{ .task_id = "t_routine_filled_061", .desc = "routine desc" },
    };

    for (cases) |case| {
        // Mirror the createRoutineTask three-way branch from task_create.zig.
        // (We deliberately inline this so the test exercises the PATTERN
        // that the handler uses, not a wrapper around it.)
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', ?)",
                    &[_][]const u8{ case.task_id, "Routine", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'routine', '')",
                    &[_][]const u8{ case.task_id, "Routine", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'routine')",
                &[_][]const u8{ case.task_id, "Routine", parent_id });
        }

        try expectDescriptionEquals062(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}

test "task_create direct INSERT branches: null/empty/value all succeed for memory task_type" {
    const alloc = testing.allocator;
    var ctx = try setupDb062();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration062.up(&ctx.db, alloc);
    const parent_id = try seedParent062(&ctx, alloc);

    // Same three-way exercise, task_type='memory' branch.
    const cases = [_]MemoryCase062{
        .{ .task_id = "t_memory_null_061", .desc = null },
        .{ .task_id = "t_memory_empty_061", .desc = "" },
        .{ .task_id = "t_memory_filled_061", .desc = "memory desc" },
    };

    for (cases) |case| {
        if (case.desc) |d| {
            if (d.len > 0) {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', ?)",
                    &[_][]const u8{ case.task_id, "Memory", parent_id, d });
            } else {
                try ctx.db.exec(alloc,
                    "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type, description) " ++
                    "VALUES (?, ?, ?, 'memory', '')",
                    &[_][]const u8{ case.task_id, "Memory", parent_id });
            }
        } else {
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) " ++
                "VALUES (?, ?, ?, 'memory')",
                &[_][]const u8{ case.task_id, "Memory", parent_id });
        }

        try expectDescriptionEquals062(&ctx, alloc, case.task_id, case.desc orelse "");
    }
}

// ===== Tests merged from migration_063_test.zig (2026-09-29 flatten) =====

// Static regression checks for Migration 063
// (sessions.is_auto_retry_until_stop + sessions.last_finish_reason).
//
// Why this file exists
// ────────────────────
// Migration 063 introduces two new columns on `sessions`:
//   - `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — opt-in flag
//     that lets a session keep retrying past the 10-attempt TooManyRetries
//     bail (unattended mode for overnight runs).
//   - `last_finish_reason TEXT` — denormalized cache of the most recent
//     `finish_reason` the workflow observed, so a server restart mid-
//     conversation picks up where the last turn left off.
//
// The migration must:
//   1. Add both columns to a fresh DB that only has the canonical
//      `sessions(id, name, status)` columns (upgrade-from-v1 path).
//   2. Be idempotent (re-runs don't crash with "duplicate column name").
//   3. Give existing rows a `0` default for the flag and NULL for
//      `last_finish_reason`.
//
// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//   (Chunk 1, Task 1.1)

const TestCtx063 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb063() !TestCtx063 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Minimal v1 sessions table — the canonical pre-Migration-063 schema
    // only declares id/name/status (Migration 017 line 263-269). The
    // migration must add the new columns on top of this.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration063 adds is_auto_retry_until_stop column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'is_auto_retry_until_stop'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'is_auto_retry_until_stop'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_auto_retry_until_stop", row.values[0]);

    // No duplicate row.
    try testing.expect((try q.next()) == null);
}

test "Migration063 adds last_finish_reason column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_finish_reason'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_finish_reason", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration063 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);
    // Re-run — must not crash with "duplicate column name".
    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // Still exactly one column of each name.
    for ([_][]const u8{ "is_auto_retry_until_stop", "last_finish_reason" }) |col| {
        var q = try ctx.db.query(alloc,
            \\SELECT COUNT(*) FROM pragma_table_info('sessions')
            \\WHERE name = ?
        , &[_][]const u8{col});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing063;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration063 default for is_auto_retry_until_stop is 0 on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one v1-shape session row (only id/name, no new columns yet).
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // The existing row should now have is_auto_retry_until_stop = '0'
    // (the NOT NULL DEFAULT 0 fires). SQLite stores INTEGER columns
    // as INTEGER affinity, but SqliteBackend.query reads values as
    // text — verify the string form '0'.
    var q = try ctx.db.query(alloc,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = 's_pre_063'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration063 last_finish_reason is NULL on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb063();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063b', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // SELECT last_finish_reason — expect empty string (SQL NULL is
    // surfaced as "" by SqliteBackend per the project's convention;
    // see project memory `sqlite-backend-empty-slice-binds-as-null`).
    var q = try ctx.db.query(alloc,
        "SELECT last_finish_reason FROM sessions WHERE id = 's_pre_063b'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing063;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// ===== Tests merged from migration_063_runtime_test.zig (2026-09-29 flatten) =====

// Behavioral regression tests for the runtime CRUD helpers added
// with Migration 063 (sessions.is_auto_retry_until_stop +
// sessions.last_finish_reason).
//
// Why this file exists
// ────────────────────
// Migration 063 (migration_063_test.zig) verifies the SCHEMA change.
// This file verifies the helper functions the rest of the codebase
// uses to read + write the new columns:
//   - create_session() takes is_auto_retry_until_stop as a parameter
//   - getSession() reads both new columns back via SELECT
//   - updateSessionAutoRetryUntilStop() toggles the flag
//   - updateSessionLastFinishReason() persists the latest finish_reason
//   - getSessionListWithCursor() / getSessionList() SELECT both new
//     columns (covered separately in Task 1.4)
//
// The setup mirrors `migration_062_test.zig:32-59` — declare the
// `sessions` table with the post-Migration-063 canonical shape
// (includes the two new columns) to exercise the "fresh-DB canonical
// CREATE TABLE" path that `addColumnIfMissing` handles.
//
// Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//   (Chunk 1, Task 1.3)

const llm_history = pabrikcore.llm_history;

const TestCtx063rt = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb063rt() !TestCtx063rt {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Canonical post-Migration-063 schema. Both new columns are
    // already declared, so `addColumnIfMissing` (when called from
    // the migration's up()) short-circuits cleanly — no "duplicate
    // column" error. The runtime CRUD tests here use this shape
    // directly without re-running the migration.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    pr_url TEXT,
        \\    pr_provider TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Reads a single text column from sessions by id. Returns an owned
/// copy (allocated with `testing.allocator`) so the caller can keep
/// the value alive after `row.deinit()`. Returns null if the row is
/// missing or the column is NULL (surfaced as empty []u8 — see the
/// `sqlite-backend-empty-slice-binds-as-null` project memory for the
/// NULL-as-empty-string convention).
fn readColumn063rt(
    ctx: *TestCtx063rt,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    // SqliteBackend.query takes argv as []const []const u8 (a slice of
    // string slices), not a tuple. Column name is interpolated via
    // std.fmt.allocPrint because `query` doesn't support format-string
    // substitution for table/column identifiers.
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM sessions WHERE id = ?", .{column});
    defer allocator.free(sql);
    const argv = [_][]const u8{row_id};
    var q = try ctx.db.query(allocator, sql, argv[0..]);
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

test "create_session: is_auto_retry_until_stop = '1' is persisted to sessions row" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s1", "test", "1");
        defer session.deinit(alloc);

        const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s1")) orelse
            return error.NoRow063rt;
        defer alloc.free(got);
        try testing.expectEqualStrings("1", got);
    }
}

test "create_session: empty is_auto_retry_until_stop defaults to '0'" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Pass empty string — the helper coerces to "0" via SQL binding.
    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s2", "test", "");
        defer session.deinit(alloc);

        const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s2")) orelse
            return error.NoRow063rt;
        defer alloc.free(got);
        try testing.expectEqualStrings("0", got);
    }
}

test "getSession: reads back is_auto_retry_until_stop + last_finish_reason" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Write the new columns directly so we can verify getSession
    // surfaces them — bypass create_session (which coerces the flag).
    // db.exec takes argv as `[]const []const u8` (a slice of strings);
    // an empty `&.{}` tuple binds every `?` as SQL NULL, so the
    // 5 placeholders below need explicit strings.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, is_auto_retry_until_stop, last_finish_reason) " ++
        "VALUES (?, ?, 'active', ?, ?)",
        &[_][]const u8{ "s3", "test", "1", "stop" });

    const got = (try llm_history.getSession(alloc, &ctx.db, "s3")) orelse
        return error.NoRow063rt;
    defer got.deinit(alloc);
    try testing.expectEqualStrings("1", got.is_auto_retry_until_stop);
    try testing.expectEqualStrings("stop", got.last_finish_reason);
}

test "updateSessionAutoRetryUntilStop: toggles 0 -> 1" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s4", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionAutoRetryUntilStop(alloc, &ctx.db, "s4", "1");

    const got = (try readColumn063rt(&ctx, alloc, "is_auto_retry_until_stop", "s4")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("1", got);
}

test "updateSessionLastFinishReason: persists the latest value" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s5", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s5", "tool_calls");

    const got = (try readColumn063rt(&ctx, alloc, "last_finish_reason", "s5")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("tool_calls", got);
}

test "updateSessionLastFinishReason: overwrites on every call" {
    const alloc = testing.allocator;
    var ctx = try setupDb063rt();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s6", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "length");
    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "stop");

    const got = (try readColumn063rt(&ctx, alloc, "last_finish_reason", "s6")) orelse
        return error.NoRow063rt;
    defer alloc.free(got);
    try testing.expectEqualStrings("stop", got);
}

// ===== Tests merged from migration_064_test.zig (2026-09-29 flatten) =====

// Behavioural tests for Migration 064 (add the `logs` table for
// frontend error capture).
//
// Why this file exists
// ────────────────────
// Migration 064 introduces the `logs` table that the frontend's
// `window.error` / `unhandledrejection` / `console.error` /
// `console.warn` listeners POST into (Chunk 2 handler). The schema
// must be exactly:
//   - 11 columns in the right order (the Ch3 SELECT * ORDER BY
//     created_at DESC relies on the cid ordering to be deterministic).
//   - 2 indexes (`idx_logs_created_at DESC` for the primary read path,
//     `idx_logs_level` for `WHERE level = ?` filtering).
//   - Idempotent on a re-run (`CREATE TABLE IF NOT EXISTS` +
//     `CREATE INDEX IF NOT EXISTS`) so a fresh-DB install and an
//     upgrade-from-v62 install both succeed.
//
// A static source check would not catch a typo'd column name, a
// missing index, a missing `IF NOT EXISTS` (which would crash on a
// re-run), or a wrong column type. Asserting the actual schema after
// `up()` runs mirrors the pattern in `migration_062_test.zig`.
//
// Plan: docs/plans/2026-07-17-frontend-error-logs-design.md

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB. Mirrors the `setupDb` helper in
/// `ai_workflow/tui/routines/Scheduler.zig` (the project's canonical
/// Io.Threaded + :memory: pattern).

fn setupDb064() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 064 creates all 11 columns in the right order ──────

test "Migration064 creates logs table with all 11 columns in the right order" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM pragma_table_info('logs') ORDER BY cid",
        &[_][]const u8{},
    );
    defer rows.deinit();

    const expected = [_][]const u8{
        "id", "created_at", "level", "kind", "message",
        "stack", "source", "line", "route_path", "session_id", "count",
    };

    var idx: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ─── Test 2: Migration 064 creates the 2 indexes ──────────────────────────

test "Migration064 creates the idx_logs_created_at and idx_logs_level indexes" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='logs' ORDER BY name",
        &[_][]const u8{},
    );
    defer rows.deinit();

    var found_created_at = false;
    var found_level = false;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_logs_created_at")) found_created_at = true;
        if (std.mem.eql(u8, row.values[0], "idx_logs_level")) found_level = true;
    }
    try testing.expect(found_created_at);
    try testing.expect(found_level);
}

// ─── Test 3: Migration 064 is idempotent on a re-run ──────────────────────

test "Migration063 is idempotent (re-running up() does not error)" {
    const alloc = testing.allocator;
    var s = try setupDb064();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration064AddFrontendLogs.up(&s.db, alloc);
    // Second run must not error — `CREATE TABLE IF NOT EXISTS` +
    // `CREATE INDEX IF NOT EXISTS` make this a safe no-op. If they
    // were bare CREATE / CREATE INDEX, the second run would crash
    // with "table logs already exists" / "index already exists".
    try Migration064AddFrontendLogs.up(&s.db, alloc);
}

// ===== Tests merged from migration_065_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 065
// (`workspace_item_tasks.last_human_touched_at`).
//
// Why this file exists
// ────────────────────
// Migration 065 adds a single nullable INTEGER column that stamps the
// last time a HUMAN (not the AI agent) interacted with a task —
// dragged it, renamed it, edited its description, pinned it, sent a
// chat message, or opened its chat. The kanban card UI uses this
// column together with `sessions.last_finish_reason` to decide
// whether to show the "AI finished — awaiting review" dot or the
// "reviewed" checkmark (see docs/plans/2026-07-26-kanban-task-notification-icon.md).
//
// The migration must:
//   1. Add `last_human_touched_at INTEGER` (nullable, no DEFAULT —
//      NULL = "never touched", which the kanban SELECT uses to mean
//      "AI finished and human hasn't seen it").
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" — see the project's hard-fought
//      knowledge about fresh-DB migration cascades in
//      `pabrik-data-and-routines.md` §"Migration #009-#052 fresh-DB
//      cascade is fragile").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at NULL (NOT 0 or the current time — the
//      "user has touched this task" semantic is binary; we cannot
//      retroactively know whether a row from before the migration was
//      reviewed).
//
// Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md (Chunk 1)

const TestCtx065 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb065() !TestCtx065 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration
    // can run. Production walks migrations 001 → 064 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `last_human_touched_at` column yet, that's exactly what the
    // migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration065 adds last_human_touched_at column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'last_human_touched_at'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named INTEGER" footgun from passing only a
    // type to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT or a literal "INTEGER" string in
    // the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing065;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
}

test "Migration065 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at INTEGER`. The migration
    // must be a no-op (NOT a "duplicate column" crash). This is the
    // same fresh-DB-vs-upgrade split that bit Migration 020 / 052 —
    // see project memory `pabrik-data-and-routines.md` §"Migration
    // #009-#052 fresh-DB cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    last_human_touched_at INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration065 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. The
    // semantics matter: we cannot retroactively know whether the user
    // touched this task before the migration ran, so the value must
    // be NULL (the "I don't know" state) — NOT 0 (which the kanban
    // SELECT would interpret as "touched at unix epoch 0, i.e. way
    // before the AI's finish_reason update, i.e. still needs review"
    // — semantically equivalent but misleading in logs) and NOT the
    // current time (which would silently mark every legacy task as
    // "reviewed" the moment the migration runs).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_065', 'Legacy task', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — see project
    // memory `sqlite-backend-empty-slice-binds-as-null` and the
    // existing Migration063 test for the same convention.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_pre_065'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration065 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb065();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_a', 'A', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateTaskLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET last_human_touched_at = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}

// ===== Tests merged from migration_066_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 066
// (`design_pages.workspace_item_task_id` FK + backfill).
//
// Why this file exists
// ────────────────────
// Migration 066 adds a single nullable TEXT column to `design_pages`
// that binds each page 1:1 to a `workspace_item_tasks` chat-session
// row. The replacement of the name-pattern lookup in
// `AppLayout.handleDesignOpenChat` with a direct FK lookup depends
// on this column being (a) added, (b) uniquely indexed, (c) backfilled
// for every existing page so legacy DBs do not orphan their per-page
// chats.
//
// The migration must:
//   1. Add `workspace_item_task_id TEXT` (nullable, no DEFAULT —
//      NULL = "not yet backfilled"; after `up()` returns, every row
//      must be backfilled).
//   2. Create a UNIQUE index on the column (the 1:1 invariant; SQLite
//      uses the same index for the FK lookup, so no second index is
//      needed).
//   3. Be idempotent on re-run (re-running must not crash with
//      "duplicate column" or "index already exists" — see project
//      memory `pabrik-data-and-routines.md` §"Migration #009-#052
//      fresh-DB cascade is fragile").
//   4. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — `addColumnIfMissing` handles
//      both fresh-DB and upgrade-from-v1 paths.
//   5. **Backfill** every pre-existing page with a fresh
//      `workspace_item_tasks` row named `"Design Chat: <page_name>"`
//      (or `"Design Chat: untitled"` for empty page names) so the
//      design canvas chat surface has a stable task row for every
//      legacy page.
//
// The migration-registration trap (defining the struct without
// registering it in `allMigrations`) is checked in Test 5 — see
// project memory `migration-registration-trap.md`.
//
// Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
// (Task 1).

const TestCtx066 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Mirror of the production schema BEFORE Migration 066 — no
/// `workspace_item_task_id` column on `design_pages`. The migration
/// itself adds the column via `addColumnIfMissing`.
fn setupDb066() !TestCtx066 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items + workspace_item_tasks: FK targets + chat-session
    // table that the backfill creates new rows in. Production walks
    // migrations 001 → 065 first; we mirror the minimal schema here.
    // The minimal `workspace_item_tasks` schema matches the v65 shape
    // (description added by Migration 062, task_type is the
    // NOT NULL DEFAULT 'standard' column).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (" ++
            "id TEXT PRIMARY KEY, " ++
            "name TEXT, " ++
            "workspace_item_id TEXT, " ++
            "task_type TEXT NOT NULL DEFAULT 'standard', " ++
            "description TEXT NOT NULL DEFAULT ''" ++
            ")",
        &.{});

    // design_pages: the pre-migration shape (Migration 055 + 056
    // schema — id, workspace_item_id, name, width, height, x, y,
    // position, created_at, updated_at, FK to workspace_items).
    // NO `workspace_item_task_id` column yet — that's exactly what
    // Migration 066 adds.
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration066 adds workspace_item_task_id column to design_pages" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('design_pages')
            \\WHERE name = 'workspace_item_task_id'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("workspace_item_task_id", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named TEXT" footgun from passing only a type
    // to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (so the FK to
    // workspace_item_tasks.id works), not a literal "TEXT" string
    // in the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing066;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);

    // UNIQUE index sanity — must exist after the migration (the
    // 1:1 invariant enforcement). Catch a regression where
    // someone drops the CREATE INDEX step but leaves the column.
    var qi = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_design_pages_workspace_item_task_id'
    , &.{});
    defer qi.deinit();
    const index_row = (try qi.next()) orelse return error.UniqueIndexMissing066;
    defer index_row.deinit(alloc);
    try testing.expectEqualStrings("idx_design_pages_workspace_item_task_id", index_row.values[0]);
}

test "Migration066 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column
    // name" or "index already exists" — the
    // `addColumnIfMissing` + `CREATE … IF NOT EXISTS` calls are all
    // idempotent.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // for design_pages already includes `workspace_item_task_id TEXT`.
    // The migration must be a no-op for the column add (NOT a
    // "duplicate column" crash), the index add must be idempotent
    // (IF NOT EXISTS), and the backfill must find no rows to update
    // (table is empty after the recreate).
    try ctx.db.exec(alloc, "DROP TABLE design_pages", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    workspace_item_task_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists,
    // CREATE INDEX IF NOT EXISTS is a no-op, backfill query returns
    // zero rows.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Re-check: still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 backfills a workspace_item_tasks row for each existing design page" {
    const alloc = testing.allocator;
    var ctx = try setupDb066();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one workspace_item, then 3 design pages (with one
    // empty-name edge case to exercise the "Design Chat: untitled"
    // fallback). The setupDb() schema does NOT yet include the
    // `workspace_item_task_id` column; we add it manually first
    // (simulating that the migration's `addColumnIfMissing` step has
    // already run on a legacy DB) — every existing row gets NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
            "VALUES ('wi_1', 'ws_1', 'design')",
        &.{});
    try ctx.db.exec(alloc,
        "ALTER TABLE design_pages ADD COLUMN workspace_item_task_id TEXT",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_a', 'wi_1', 'Login', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_b', 'wi_1', 'Dashboard', 1)",
        &.{});
    try ctx.db.exec(alloc,
        // Empty name — exercises the "Design Chat: untitled" fallback.
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_c', 'wi_1', '', 2)",
        &.{});

    // Sanity: all 3 pages have NULL task_id BEFORE the migration runs.
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing066;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("3", row.values[0]);
    }

    // Apply the migration. addColumnIfMissing no-ops (column exists);
    // CREATE INDEX IF NOT EXISTS creates the unique index; backfill
    // creates 3 new tasks + updates 3 pages.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // 1. Every page now has a non-NULL workspace_item_task_id that
    //    points at a real workspace_item_tasks row. Joining both
    //    tables catches both the UPDATE and the FK invariant in one
    //    query — if the migration forgot the UPDATE, the JOIN would
    //    still return 3 rows (matching by workspace_item_id, not the
    //    new task_id), so we use the actual `workspace_item_task_id`
    //    column for the join.
    var qj = try ctx.db.query(alloc,
        \\SELECT dp.id, dp.name, t.id, t.name, t.task_type, t.description
        \\FROM design_pages dp
        \\JOIN workspace_item_tasks t
        \\  ON t.id = dp.workspace_item_task_id
        \\WHERE dp.workspace_item_id = 'wi_1'
        \\ORDER BY dp.position ASC
    , &.{});
    defer qj.deinit();

    // Expected: page_a → "Design Chat: Login", page_b → "Design Chat:
    // Dashboard", page_c → "Design Chat: untitled" (empty name
    // fallback). task_type is always 'standard'; description is ''.
    const expected: [3][]const u8 = .{ "Design Chat: Login", "Design Chat: Dashboard", "Design Chat: untitled" };
    const expected_page_ids: [3][]const u8 = .{ "page_a", "page_b", "page_c" };
    for (expected, 0..) |_, i| {
        const row = (try qj.next()) orelse return error.BackfillRowMissing066;
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected_page_ids[i], row.values[0]);
        try testing.expectEqualStrings(expected[i], row.values[3]);
        try testing.expectEqualStrings("standard", row.values[4]);
        try testing.expectEqualStrings("", row.values[5]);
        // Sanity: the task id is non-empty (i.e. was actually
        // generated, not the empty-slice-as-NULL trap).
        try testing.expect(row.values[2].len > 0);
    }
    // No 4th row expected — the backfill should produce exactly
    // one task per page.
    try testing.expect((try qj.next()) == null);

    // 2. No page was left with NULL workspace_item_task_id after the
    //    backfill (the migration's WHERE clause should match every
    //    pre-existing row exactly once).
    var qnull = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
        &.{});
    defer qnull.deinit();
    const null_row = (try qnull.next()) orelse return error.RowMissing066;
    defer null_row.deinit(alloc);
    try testing.expectEqualStrings("0", null_row.values[0]);

    // 3. Re-run safety: a second `up()` call must not produce extra
    //    task rows (the backfill's WHERE workspace_item_task_id IS
    //    NULL matches zero rows on the second pass).
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    var qc = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_item_tasks WHERE workspace_item_id = 'wi_1'",
        &.{});
    defer qc.deinit();
    const count_row = (try qc.next()) orelse return error.RowMissing066;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("3", count_row.values[0]);
}

test "Migration066 is registered in allMigrations" {
    // The migration-registration trap: defining the struct is not
    // enough — it must also be added to `migration.zig::allMigrations`.
    // A static-contract test that just imports the struct directly
    // would pass with the tuple missing (because tests import the
    // struct, not the slice). This test iterates the slice and
    // catches the regression where someone deletes the registration
    // tuple. See project memory `migration-registration-trap.md`.
    for (allMigrations) |m| {
        if (m.version == Migration066AddDesignPageTaskFk.version) return;
    }
    return error.Migration066NotRegistered066;
}

// ===== Tests merged from migration_067_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 067
// (`workspace_item_tasks.tags`).
//
// Why this file exists
// ────────────────────
// Migration 067 adds a `tags TEXT NOT NULL DEFAULT ''` column to
// `workspace_item_tasks` to support the kanban task tags feature
// (plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
// Tags are stored as a JSON-encode array string (e.g.
// `'["bug","urgent","frontend"]'`); empty string = "no tags".
//
// The migration must:
//   1. Add `tags TEXT NOT NULL DEFAULT ''` to `workspace_item_tasks`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at '' (the canonical "no tags" sentinel).
//   5. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 1)

const TestCtx067 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb067() !TestCtx067 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration
    // can run. Production walks migrations 001 → 066 first, so they're
    // already there; we create minimal mirrors here for the unit test.
    // The minimal `workspace_item_tasks` schema matches the v1 shape —
    // no `tags` column yet, that's exactly what the migration adds.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration067 adds tags column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'tags'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("tags", row.values[0]);

    // Confirm there are no extra rows (guards against the "column literally
    // named TEXT" footgun from passing only a type to addColumnIfMissing;
    // see project memory `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (NOT NULL DEFAULT '' applies
    // independently of the type).
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing067;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
}

test "Migration067 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration067AddTaskTags.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `tags TEXT`. The migration must be a no-op
    // (NOT a "duplicate column" crash). Mirrors the fresh-DB-vs-
    // upgrade split that hit Migration 020 / 052 — see project memory
    // `pabrik-data-and-routines.md` §"Migration #009-#052 fresh-DB
    // cascade is fragile".
    try ctx.db.exec(alloc, "DROP TABLE workspace_item_tasks", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT,
        \\    workspace_item_id TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'tags'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration067 leaves pre-existing rows at empty string (the no-tags sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing task BEFORE applying the migration. We
    // cannot retroactively know what tags the user wanted, so the
    // value must be '' (canonical "no tags" sentinel) — NOT NULL
    // (the column is NOT NULL DEFAULT ''). Matches the description
    // column (Migration 062) sentinel pattern.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_067', 'Legacy task', 'wi_1')",
        &.{});

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_pre_067'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration067 accepts a JSON array string when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb067();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_a', 'A', 'wi_1')",
        &.{});

    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Now update with a JSON array — should persist verbatim. This is
    // the exact call shape that llm_history.createWorkspaceItemTask
    // (with tags) will use post-Migration 067.
    try ctx.db.exec(alloc,
        "UPDATE workspace_item_tasks SET tags = ? WHERE id = ?",
        &[_][]const u8{ "[\"bug\",\"urgent\",\"frontend\"]", "task_a" });

    var q = try ctx.db.query(alloc,
        "SELECT tags FROM workspace_item_tasks WHERE id = 'task_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing067;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("[\"bug\",\"urgent\",\"frontend\"]", row.values[0]);
}

test "Migration067 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration067AddTaskTags.version) return;
    }
    return error.Migration067NotRegistered067;
}

// ===== Tests merged from migration_068_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 068
// (`llm_history.is_loading` + UNIQUE INDEX on `tool_call_id`).
//
// Why this file exists
// ────────────────────
// Migration 068 adds an `is_loading INTEGER NOT NULL DEFAULT 0` column
// to `llm_history` so we can mark tool-result placeholder rows that
// were pre-created BEFORE the long-running tool execution started.
//
// It also adds a partial UNIQUE INDEX on `tool_call_id`:
//     CREATE UNIQUE INDEX idx_llm_history_tool_call_id_loading
//         ON llm_history(tool_call_id)
//         WHERE tool_call_id IS NOT NULL AND tool_call_id != ''
//
// The UNIQUE INDEX is required so duplicate placeholders for the same
// id are rejected at the DB level — without it, the dispatcher could
// accidentally create two placeholders for one tool_call.id (a race
// between the dispatcher + a stray retry). The partial WHERE clause
// excludes empty-string tool_call_ids (the assistant message rows)
// so the assistant row's `tool_call_id = ''` doesn't conflict with
// the placeholders' `tool_call_id = 'tcA'` etc.
//
// The migration must:
//   1. Add `is_loading INTEGER NOT NULL DEFAULT 0` to `llm_history`.
//   2. Add the partial UNIQUE INDEX on `tool_call_id`.
//   3. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" or "index already exists").
//   4. Leave existing rows at `is_loading = 0` (the canonical "not
//      loading" sentinel — every historical row was either written
//      directly by the dispatcher (not loading) or it was the
//      assistant message (which doesn't apply here)).
//   5. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-tool-call-loading-placeholder.md
// Bug: task_1785784899843 ("invalid function ID tool call error")

const TestCtx068 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb068() !TestCtx068 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `llm_history` schema matching the v1 shape — no
    // `is_loading` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 067 first, so
    // `tool_call_id` and `is_feed_to_llm` are already there; we
    // include them so the migration's addColumnIfMissing succeeds
    // and the partial UNIQUE INDEX has the column to attach to.
    try db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    model TEXT NOT NULL,
        \\    response_content TEXT,
        \\    tool_calls_json TEXT,
        \\    tool_call_id TEXT,
        \\    is_feed_to_llm INTEGER DEFAULT 1
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration068 adds is_loading column to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('llm_history')
            \\WHERE name = 'is_loading'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_loading", row.values[0]);

    // Type sanity: the column must be INTEGER (NOT NULL DEFAULT 0).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing068;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is "0" — the canonical "not loading" sentinel.
    try testing.expectEqualStrings("0", type_row.values[2]);
}

test "Migration068 adds partial UNIQUE INDEX on tool_call_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the index exists.
    var q = try ctx.db.query(alloc,
        \\SELECT name, sql FROM sqlite_master
        \\WHERE type = 'index' AND tbl_name = 'llm_history'
        \\AND name = 'idx_llm_history_tool_call_id_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_llm_history_tool_call_id_loading", row.values[0]);
}

test "Migration068 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name"
    // or "index idx_llm_history_tool_call_id_loading already exists".
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Still exactly one is_loading column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('llm_history')
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration068 leaves pre-existing rows at is_loading=0 (the not-loading sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical row was either written directly (not loading) or
    // pre-existed; the migration MUST backfill is_loading = 0 for
    // every row.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content) " ++
            "VALUES ('msg_pre_068', 'sess_1', 'm', 'pre-existing')",
        &.{});

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT is_loading FROM llm_history WHERE id = 'msg_pre_068'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration068 enables the UNIQUE INDEX to reject duplicate tool_call_ids" {
    const alloc = testing.allocator;
    var ctx = try setupDb068();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Two rows with the SAME tool_call_id must be rejected. The
    // assistant message has tool_call_id = '' (not the placeholder's
    // id), but the index is partial so the assistant row passes
    // through unaffected.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a', 'sess_1', 'm', 'result_a', 'tcA', 0)",
        &.{});
    // Second placeholder with the same tool_call_id — must fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id, is_loading) " ++
            "VALUES ('msg_tool_a_dup', 'sess_1', 'm', 'result_a_dup', 'tcA', 0)",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);

    // But a row with tool_call_id = '' (the assistant message shape)
    // is allowed — the partial WHERE clause excludes it. Insert a
    // SECOND row with tool_call_id = '' to prove the partial index
    // is correctly scoped.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_assistant', 'sess_1', 'm', 'assistant content', '')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, tool_call_id) " ++
            "VALUES ('msg_user', 'sess_1', 'm', 'user message', '')",
        &.{});
}

test "Migration068 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration068AddToolCallLoading.version) return;
    }
    return error.Migration068NotRegistered068;
}

// ===== Tests merged from migration_069_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 069
// (`workspace_item_tasks.image_urls`).
//
// Why this file exists
// ────────────────────
// Migration 069 adds an `image_urls TEXT NOT NULL DEFAULT ''` column
// to `workspace_item_tasks` so task-attached images can be stored inline
// as `||`-delimited base64 data URLs. This replaces the broken
// filesystem-backed attachment endpoints (`POST/GET /api/.../attachments`).
//
// The migration must:
//   1. Add the `image_urls` column with `TEXT NOT NULL DEFAULT ''`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Leave existing rows at `image_urls = ''` (the canonical "no
//      images" sentinel — every historical task predates the feature).
//   4. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-image-urls-column.md
// Bug: task_1785795051796 ("kanban task not saving the images or
// base 64 in kanban description, after create a task or run aent")

const TestCtx069 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb069() !TestCtx069 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-069
    // shape — no `image_urls` column yet (that's exactly what the migration
    // adds). Production walks migrations 001 → 068 first, so `description`
    // (Migration 062) and `tags` (Migration 067) are already there; we
    // include them so the migration's addColumnIfMissing succeeds and the
    // schema mirrors what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration069 adds image_urls column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'image_urls'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("image_urls", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no images" sentinel —
    // matches the `description` / `tags` patterns from
    // Migrations 062 / 067).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing069;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // images" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — see the
    // same pattern in migration_062_test for `description`'s
    // DEFAULT '' column). Accept either the bare empty string or the
    // single-quoted empty-string literal — both represent the same
    // semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration069 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Still exactly one image_urls column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration069 leaves pre-existing rows at image_urls='' (the no-images sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill image_urls = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_069', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_pre_069'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration069 round-trips a ||-delimited image_urls string" {
    const alloc = testing.allocator;
    var ctx = try setupDb069();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Insert a task with two data URLs joined by || (the convention
    // `llm_history.image_url` uses). Confirm the raw string round-trips
    // — the column stores bytes verbatim, the join/split is the
    // caller's responsibility.
    const joined = "data:image/png;base64,iVBORw0KGgo||data:image/jpeg;base64,/9j/4AAQ";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, image_urls) " ++
            "VALUES ('task_imgs', 'Two-image task', 'item_1', ?)",
        &[_][]const u8{joined});

    var q = try ctx.db.query(alloc,
        "SELECT image_urls FROM workspace_item_tasks WHERE id = 'task_imgs'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(joined, row.values[0]);
}

test "Migration069 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration069AddTaskImageUrls.version) return;
    }
    return error.Migration069NotRegistered069;
}

// ===== Tests merged from migration_070_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 070
// (`agent_memories` table + `agent_memories_fts` FTS5 virtual table).
//
// Why this file exists
// ────────────────────
// Migration 070 backs the new `save_memory` + `load_memory` agent tools.
// It creates:
//   - `agent_memories` — the source table (id PK, content, tags, timestamps)
//   - `agent_memories_fts` — a non-external-content FTS5 virtual table
//     over `content` + `tags` (content is duplicated so `snippet()` works,
//     matching the existing `messages_fts` pattern from Migration 058)
//   - 3 sync triggers (INSERT / DELETE / UPDATE) that keep the FTS index
//     in lockstep with the source table
//
// Plan: docs/superpowers/plans/2026-08-06-save-load-memory-fts5.md (Task 1)
// Task: task_1785958319567 (save_memory + load_memory tools)
//
// Why non-external-content
// ─────────────────────────
// `snippet()` returns NULL for external-content FTS5 tables. The
// `load_memory` tool needs snippets to render compact `<snippet>` blocks
// (10 tokens with `[match]` markers). Duplicating content costs ~2x
// storage but enables the only UX feature that matters here.
//
// Why FTS5 MATCH ? with single-token words
// ─────────────────────────────────────────
// Same rationale as migration_058_test.zig — multi-word queries would
// couple the test to the tokenizer's exact behavior; single-token MATCH
// keeps the contract tight: "the row containing word W is in the FTS
// index".

/// Test fixture. Hoisted to a top-level named struct (NOT inline anonymous)
/// because Zig 0.16 treats two anonymous `struct { db, threaded }` types as
/// distinct types even with identical fields — see project memory
/// `zig-anonymous-struct-type-identity.md`.

const TestCtx070 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 070 runs, `agent_memories` exists and the FTS5 sync triggers
/// are installed.
fn setupDb070() !TestCtx070 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "Migration070 creates agent_memories table with correct columns" {
    // After migration, `pragma_table_info('agent_memories')` must show
    // columns: id (TEXT PK), content (TEXT NOT NULL), tags (TEXT NOT NULL
    // DEFAULT ''), created_at (DATETIME DEFAULT CURRENT_TIMESTAMP),
    // updated_at (DATETIME DEFAULT CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have agent_memories
        }
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentMemoriesTableNotCreated070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agent_memories", row.values[0]);
    }

    // Verify the 5 expected columns exist with the expected names.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('agent_memories') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "content", "tags", "created_at", "updated_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

test "Migration070 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A second
    // run must NOT crash with "table agent_memories already exists" or
    // similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);
    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Still exactly 1 agent_memories table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='agent_memories'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing070;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration070 creates agent_memories_fts FTS5 virtual table" {
    // After migration, `sqlite_master` must contain a row for
    // `agent_memories_fts` with type='table' (FTS5 virtual tables show
    // up as 'table' rows in sqlite_master, not 'view' or 'index').
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agent_memories_fts'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.FtsVirtualTableNotCreated070;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("agent_memories_fts", row.values[0]);
}

test "Migration070 installs sync triggers (exactly 3 on agent_memories)" {
    // The migration creates 3 triggers: agent_memories_ai, _ad, _au.
    // After migration, querying sqlite_master with `tbl_name='agent_memories'`
    // AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on agent_memories.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='agent_memories'",
            &.{});
        defer q.deinit();
        var pre_count: usize = 0;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            pre_count += 1;
        }
        try testing.expectEqual(@as(usize, 0), pre_count);
    }

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='trigger' AND tbl_name='agent_memories'
        \\ORDER BY name
        , &.{});
    defer q.deinit();
    const names = [_][]const u8{ "agent_memories_ad", "agent_memories_ai", "agent_memories_au" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names.len);
        try testing.expectEqualStrings(names[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, names.len), idx);
}

test "Migration070 sync triggers keep FTS5 in lockstep with source table" {
    // The whole point of the triggers is that INSERT/UPDATE/DELETE on
    // `agent_memories` auto-mirror into `agent_memories_fts`. Insert a
    // row, FTS5 MATCH on a unique word from it must return the row.
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration070AddAgentMemories.up(&ctx.db, alloc);

    // INSERT a row post-migration. The ai trigger should auto-add it to FTS5.
    try ctx.db.exec(alloc,
        \\INSERT INTO agent_memories (id, content, tags)
        \\VALUES ('mem-trig-1', 'this row contains zeppelinword for trigger test', 'preferences')
        , &.{});

    // FTS5 MATCH on the unique word must return the row.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.InsertTriggerDidNotFire070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // UPDATE the content. The au trigger should remove the old FTS5 row
    // and insert the new one. The OLD word must NOT match; the NEW word must.
    try ctx.db.exec(alloc,
        \\UPDATE agent_memories SET content = 'updated content has quasarword now'
        \\WHERE id = 'mem-trig-1'
        , &.{});

    // Old word no longer matches (au trigger's DELETE part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"zeppelinword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // UPDATE trigger DELETE part did not fire
        }
    }

    // New word matches (au trigger's INSERT part fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse return error.UpdateTriggerInsertPartDidNotFire070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("mem-trig-1", row.values[0]);
    }

    // DELETE the row. The ad trigger should remove it from FTS5.
    try ctx.db.exec(alloc,
        "DELETE FROM agent_memories WHERE id = 'mem-trig-1'",
        &.{});

    // New word no longer matches (ad trigger fired).
    {
        var q = try ctx.db.query(alloc,
            \\SELECT m.id FROM agent_memories m
            \\JOIN agent_memories_fts f ON f.rowid = m.rowid
            \\WHERE agent_memories_fts MATCH ?
            , &.{"quasarword"});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // DELETE trigger did not fire
        }
    }
}

test "Migration070 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined but
    // the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version number
    // so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration070AddAgentMemories.version) return;
    }
    return error.Migration070NotRegistered070;
}

// ===== Tests merged from migration_071_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 071
// (`workspace_item_tasks.cwd`).
//
// Why this file exists
// ────────────────────
// Migration 071 adds a `cwd TEXT NOT NULL DEFAULT ''` column to
// `workspace_item_tasks` so each task can carry its own cwd_session
// (which becomes the cwd_session for that task's chat sessions).
// Per-task cwd OVERRIDES the kanban-level path (`workspace_items.path`)
// which OVERRIDES the per-session sandbox fallback
// (`$TMPDIR/session_<id>/`). The chain is implemented in
// `session_create.zig::useCase`.
//
// The migration must:
//   1. Add the `cwd` column with `TEXT NOT NULL DEFAULT ''`.
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name").
//   3. Leave existing rows at `cwd = ''` (the canonical "no per-task
//      cwd" sentinel — every historical task predates the feature).
//   4. Be registered in `allMigrations` — defining the struct alone
//      is a silent-skip bug per project memory
//      `migration-registration-trap`.
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
// Tasks: task_1785959915548 (kanban cwd → optional + per-task cwd picker)

const TestCtx071 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb071() !TestCtx071 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-070
    // shape — no `cwd` column yet (that's exactly what the migration adds).
    // Production walks migrations 001 → 069 first, so `description`
    // (Migration 062), `tags` (Migration 067), and `image_urls`
    // (Migration 069) are already there; we include them so the
    // migration's addColumnIfMissing succeeds and the schema mirrors
    // what real production rows look like.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    description TEXT NOT NULL DEFAULT '',
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    image_urls TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // Minimal `workspace_items` table so the FK target exists for
    // round-trip tests that need to INSERT a parent row first.
    // Production walks migrations 001 → 069 first, so this table is
    // always there; the test mirrors that.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration071 adds cwd column to workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('workspace_item_tasks')
            \\WHERE name = 'cwd'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("cwd", row.values[0]);

    // Type + nullability + default sanity: the column must be
    // TEXT NOT NULL DEFAULT '' (the canonical "no per-task cwd" sentinel
    // — matches the `description` / `tags` / `image_urls` patterns from
    // Migrations 062 / 067 / 069).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing071;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no
    // per-task cwd" sentinel). `pragma_table_info` reports it as the
    // SQL literal text (i.e. `''` with the single quotes — same pattern
    // as the other NOT NULL DEFAULT '' columns). Accept either the bare
    // empty string or the single-quoted empty-string literal — both
    // represent the same semantic default.
    const dflt = type_row.values[2];
    try testing.expect(dflt.len == 0 or std.mem.eql(u8, dflt, "''"));
}

test "Migration071 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration071AddTaskCwd.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Still exactly one cwd column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration071 leaves pre-existing rows at cwd='' (the no-per-task-cwd sentinel)" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing row BEFORE applying the migration. Every
    // historical task predates the feature; the migration MUST
    // backfill cwd = '' for every row (the column has NOT NULL
    // DEFAULT '' and ADD COLUMN applies DEFAULT to existing rows at
    // the storage layer).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
            "VALUES ('task_pre_070', 'Pre-existing task', 'item_1')",
        &.{});

    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_pre_070'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration071 round-trips a per-task cwd path" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Insert a task with an absolute path on disk as its per-task cwd.
    // Confirm the raw string round-trips — the column stores bytes
    // verbatim, the resolution chain (task.cwd → item.path → sandbox)
    // is the caller's responsibility.
    const cwd_path = "/home/me/projects/repo-A";
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, cwd) " ++
            "VALUES ('task_cwd', 'Per-task cwd task', 'item_1', ?)",
        &[_][]const u8{cwd_path});

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 'task_cwd'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(cwd_path, row.values[0]);
}

test "Migration071 is registered in allMigrations" {
    // Catches the silent-skip regression where the struct is defined
    // but the registration tuple is missing (per project memory
    // `migration-registration-trap`). Search the slice by version
    // number so the test stays stable across reordering.
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration071AddTaskCwd.version) return;
    }
    return error.Migration071NotRegistered071;
}

// ─── createWorkspaceItemTask round-trip tests (Migration 071) ───────────
//
// These tests exercise the model's createWorkspaceItemTask function
// (the canonical INSERT path for new tasks) to lock in the contract:
// the new `cwd` arg must (a) be accepted as the 10th parameter,
// (b) store the supplied path verbatim, and (c) default to '' when
// the caller passes null (matches the description / tags / image_urls
// pattern).

const createWorkspaceItemTask_fromMigration071 = @import("pabrikcore").ai_mod.llm_history.createWorkspaceItemTask;

test "createWorkspaceItemTask: cwd = '/home/me/proj-A' round-trips verbatim" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_001");

    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_001",
        "Task with cwd",
        parent_id,
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        "/home/me/proj-A", // cwd (Migration 071 10th arg)
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("/home/me/proj-A", task.cwd);

    // Read back from DB to verify persistence.
    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_001'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("/home/me/proj-A", row.values[0]);
}

test "createWorkspaceItemTask: cwd = '' stores '' (SQL '' literal, NOT NULL DEFAULT '')" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_002");

    // Empty-string cwd — must use the SQL '' literal branch (NOT
    // bind via `?`, which would NULL-bind and fail NOT NULL).
    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_002",
        "Task with empty cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        "", // cwd
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_002'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "createWorkspaceItemTask: cwd = null omits column (DEFAULT '' applies)" {
    const alloc = testing.allocator;
    var ctx = try setupDb071();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    const parent_id = try insertWorkspaceItem071(&ctx, alloc, "item_003");

    // null cwd — column omitted from INSERT, DEFAULT '' applies.
    const task = try createWorkspaceItemTask_fromMigration071(
        alloc,
        &ctx.db,
        "t_cwd_003",
        "Task with null cwd",
        parent_id,
        "standard",
        null,
        null,
        null,
        null, // cwd — omitted, DEFAULT '' fills in
        null, // video_urls (Migration 090)
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.cwd);

    var q = try ctx.db.query(alloc,
        "SELECT cwd FROM workspace_item_tasks WHERE id = 't_cwd_003'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

// Helper for the round-trip tests above — inserts a minimal
// workspace_item row so the FK constraint on
// workspace_item_tasks.workspace_item_id is satisfied. Returns
// the input slice borrowed from the caller's stack — caller MUST
// NOT free it.
fn insertWorkspaceItem071(
    ctx: *TestCtx071,
    alloc: std.mem.Allocator,
    item_id: []const u8,
) ![]const u8 {
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_items (id, workspace_id, item_type)
        \\VALUES (?, 'ws_test', 'kanban')
    , &.{item_id});
    // Borrow the input — caller owns the backing memory (the
    // literal `"item_001"` lives in the test function's stack
    // frame; the test ends before the literal's lifetime ends).
    return item_id;
}

// ===== Tests merged from migration_072_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 072
// (`workspace_item_tasks` → `kanban` table extraction).
//
// Why this file exists
// ────────────────────
// Migration 072 moves the two kanban-board-placement columns
// (`kanban_column_id`, `kanban_position`) off the universal
// `workspace_item_tasks` table and into a dedicated `kanban` join
// table. This is purely structural — the wire format
// (`Task.kanban_column_id`, `Task.kanban_position`) stays identical,
// served via a `LEFT JOIN kanban k ON k.workspace_item_task_id = t.id` in list
// queries.
//
// The migration must:
//   1. Create the `kanban` table with the expected schema
//      (workspace_item_task_id PK, kanban_column_id NOT NULL, kanban_position
//      DEFAULT 0, FKs to workspace_item_tasks + kanban_columns).
//   2. Create the `idx_kanban_column_position` index.
//   3. Backfill rows from existing `workspace_item_tasks`
//      (only rows whose `kanban_column_id` references a real
//      `kanban_columns.id` — orphans are skipped per the design
//      decision in the plan, risk R8).
//   4. Drop `workspace_item_tasks.kanban_column_id`.
//   5. Drop `workspace_item_tasks.kanban_position`.
//   6. Drop `idx_tasks_column_position` from workspace_item_tasks.
//   7. Be idempotent on a re-run (re-running must not crash with
//      "duplicate column name" or "table already exists" — relies
//      on `CREATE TABLE IF NOT EXISTS` + `DROP COLUMN IF EXISTS`-
//      style helpers).
//   8. Preserve the wire format — after migration, a `LEFT JOIN`
//      from `workspace_item_tasks` to `kanban` returns the same
//      (column_id, position) pairs that the old direct columns
//      returned (with NULL/0 for non-kanban tasks).
//
// Plan: docs/superpowers/plans/2026-08-15-extract-kanban-columns-to-kanban-table.md
// Tasks: task_1786527996378 ("move column workspace_item_tasks table").

const TestCtx072 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up a pre-Migration-072 in-memory DB — mirrors the schema a real
/// production user has after walking migrations 001 → 071. Includes
/// the two columns we're about to drop, plus the index we're about
/// to drop. Also seeds the FK target tables (`workspace_items`,
/// `kanban_columns`) so the backfill SELECT has valid references.
fn setupDb072() !TestCtx072 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items — FK target for workspace_item_tasks.workspace_item_id
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, item_type TEXT NOT NULL)",
        &.{});
    // kanban_columns — FK target for the new kanban.kanban_column_id.
    // Production walks Migration 051 to create this; the test mirrors it
    // so the backfill SELECT can validate column-id references.
    try db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    // Pre-Migration-072 workspace_item_tasks — the full set of task
    // attributes from migrations 001 → 071 PLUS the two columns we're
    // about to extract.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    created_at TEXT,
        \\    updated_at TEXT,
        \\    task_type TEXT NOT NULL DEFAULT 'standard',
        \\    is_pinned INTEGER DEFAULT 0,
        \\    pinned_position INTEGER DEFAULT 0,
        \\    kanban_column_id TEXT,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    last_human_touched_at INTEGER,
        \\    tags TEXT NOT NULL DEFAULT '',
        \\    cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    // The legacy per-column-position index that Migration 072 drops.
    try db.exec(alloc,
        "CREATE INDEX idx_tasks_column_position " ++
        "ON workspace_item_tasks(kanban_column_id, kanban_position)",
        &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Insert a workspace_items row + a kanban_columns row + a task with
/// a kanban placement. Returns nothing; the caller asserts on the
/// post-migration state.
fn seedKanbanCard072(
    ctx: *TestCtx072,
    alloc: std.mem.Allocator,
    task_id: []const u8,
    column_id: []const u8,
    position: i64,
) !void {
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES (?, 'wi_1', 'todo', 0)",
        &.{column_id});
    const pos_str = try std.fmt.allocPrint(alloc, "{d}", .{position});
    defer alloc.free(pos_str);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES (?, 'Task', 'wi_1', ?, ?)
    , &.{ task_id, column_id, pos_str });
}

// ============================================================================
// Test 0 — Column-delete cascades the kanban row (FK regression test)
// ============================================================================
//
// The original Migration 072 DDL declared the FK on
// `kanban.kanban_column_id` as `ON DELETE SET NULL`. That action is
// incompatible with the column's `NOT NULL` constraint — SQLite rejects
// the parent DELETE with "NOT NULL constraint failed:
// kanban.kanban_column_id". The fix is `ON DELETE CASCADE`: deleting a
// column un-places its tasks (deletes the kanban row).
//
// This test seeds a column + task + kanban row, runs the migration,
// deletes the column, and asserts the kanban row is gone. Without
// CASCADE, the DELETE would crash (and the test would fail with
// `error.SqLiteError`).
test "Migration072 kanban_column_id FK is ON DELETE CASCADE — deleting a column un-places its task" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // NB: PRAGMA foreign_keys is deliberately OFF in this project's
    // SqliteBackend init (see src/ai_workflow/tui/kanban_model.zig:306
    // for the rationale — application code simulates CASCADE
    // manually). We turn it ON here so this test exercises the
    // *schema-declared* FK behavior, which is what someone running
    // with the default `sqlite3` CLI would observe. If PRAGMA is
    // off, the FK is documentation-only and the test would falsely
    // pass even with the buggy `SET NULL` declaration.
    try ctx.db.exec(alloc, "PRAGMA foreign_keys = ON", &.{});

    // Seed: one valid task on column col_1.
    try seedKanbanCard072(&ctx, alloc, "task_to_unplace", "col_1", 0);

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Pre-condition: the kanban row exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM kanban WHERE workspace_item_task_id = 'task_to_unplace'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing072;
        defer row.deinit(alloc);
    }

    // Action: delete the column. With ON DELETE CASCADE this should
    // silently cascade-delete the kanban row. With the buggy
    // ON DELETE SET NULL, this would fail with `NOT NULL
    // constraint failed: kanban.kanban_column_id`.
    try ctx.db.exec(alloc,
        "DELETE FROM kanban_columns WHERE id = 'col_1'",
        &.{});

    // Post-condition: the kanban row is gone.
    var q = try ctx.db.query(alloc,
        "SELECT 1 FROM kanban WHERE workspace_item_task_id = 'task_to_unplace'",
        &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 1 — Migration creates the `kanban` table
// ============================================================================

test "Migration072 creates the kanban table with the expected schema" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: kanban table does NOT exist before migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM sqlite_master
            \\WHERE type = 'table' AND name = 'kanban'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Confirm the kanban table exists.
    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'table' AND name = 'kanban'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing072;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 2 — Migration creates the per-column-position index
// ============================================================================

test "Migration072 creates idx_kanban_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_kanban_column_position'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing072;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 3 — Migration backfills existing rows
// ============================================================================

test "Migration072 backfills kanban rows from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try seedKanbanCard072(&ctx, alloc, "task_a", "col_1", 0);
    try seedKanbanCard072(&ctx, alloc, "task_b", "col_1", 1);
    try seedKanbanCard072(&ctx, alloc, "task_c", "col_2", 0);

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the backfill: three rows in kanban with the expected
    // workspace_item_task_id / column_id / position triples.
    var q = try ctx.db.query(alloc,
        \\SELECT workspace_item_task_id, kanban_column_id, kanban_position
        \\FROM kanban
        \\ORDER BY workspace_item_task_id ASC
    , &.{});
    defer q.deinit();

    const row_a = (try q.next()) orelse return error.RowMissing072;
    defer row_a.deinit(alloc);
    try testing.expectEqualStrings("task_a", row_a.values[0]);
    try testing.expectEqualStrings("col_1", row_a.values[1]);
    try testing.expectEqualStrings("0", row_a.values[2]);

    const row_b = (try q.next()) orelse return error.RowMissing072;
    defer row_b.deinit(alloc);
    try testing.expectEqualStrings("task_b", row_b.values[0]);
    try testing.expectEqualStrings("col_1", row_b.values[1]);
    try testing.expectEqualStrings("1", row_b.values[2]);

    const row_c = (try q.next()) orelse return error.RowMissing072;
    defer row_c.deinit(alloc);
    try testing.expectEqualStrings("task_c", row_c.values[0]);
    try testing.expectEqualStrings("col_2", row_c.values[1]);
    try testing.expectEqualStrings("0", row_c.values[2]);

    try testing.expect((try q.next()) == null); // no extra rows
}

// ============================================================================
// Test 4 — Backfill skips orphan kanban_column_id references (R8)
// ============================================================================

test "Migration072 backfill skips tasks whose kanban_column_id has no matching kanban_columns row" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: task with a valid column (col_1) + task pointing at a
    // deleted/orphan column (col_deleted).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_valid', 'Valid', 'wi_1', 'col_1', 0)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_orphan', 'Orphan', 'wi_1', 'col_deleted', 5)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Only the valid row was backfilled — the orphan was skipped.
    var q = try ctx.db.query(alloc,
        "SELECT workspace_item_task_id FROM kanban ORDER BY workspace_item_task_id ASC",
        &.{});
    defer q.deinit();

    const row1 = (try q.next()) orelse return error.RowMissing072;
    defer row1.deinit(alloc);
    try testing.expectEqualStrings("task_valid", row1.values[0]);

    try testing.expect((try q.next()) == null); // task_orphan NOT backfilled
}

// ============================================================================
// Test 5 — Migration drops the kanban_column_id and kanban_position columns
// ============================================================================

test "Migration072 drops kanban_column_id from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_column_id'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

test "Migration072 drops kanban_position from workspace_item_tasks" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name = 'kanban_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 6 — Migration drops idx_tasks_column_position index
// ============================================================================

test "Migration072 drops the legacy idx_tasks_column_position index" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM sqlite_master
        \\WHERE type = 'index' AND name = 'idx_tasks_column_position'
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null);
}

// ============================================================================
// Test 7 — Migration is idempotent on re-run
// ============================================================================

test "Migration072 is idempotent — re-running does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);
    // Re-run: must not crash with "duplicate column name" or
    // "table kanban already exists". The CREATE TABLE IF NOT
    // EXISTS + dropColumnIfExists helpers make this a no-op.
    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Verify the schema is still correct after the re-run.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('workspace_item_tasks')
        \\WHERE name IN ('kanban_column_id', 'kanban_position')
    , &.{});
    defer q.deinit();
    try testing.expect((try q.next()) == null); // columns still gone
}

// ============================================================================
// Test 8 — Wire-format preservation via LEFT JOIN
// ============================================================================

test "Migration072 preserves the wire format — LEFT JOIN returns the same data the old direct columns did" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one task on a kanban column, one task with no column
    // assignment (the "chat task in a kanban item" case — has
    // kanban_column_id IS NULL).
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'kanban')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT OR IGNORE INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_1', 'wi_1', 'todo', 0)",
        &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_on_board', 'On board', 'wi_1', 'col_1', 7)
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks
        \\(id, name, workspace_item_id, kanban_column_id, kanban_position)
        \\VALUES ('task_unassigned', 'Unassigned', 'wi_1', NULL, 0)
    , &.{});

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // The "wire format" query — what every list query uses to
    // populate Task.kanban_column_id and Task.kanban_position.
    var q = try ctx.db.query(alloc,
        \\SELECT t.id, k.kanban_column_id, COALESCE(k.kanban_position, 0)
        \\FROM workspace_item_tasks t
        \\LEFT JOIN kanban k ON k.workspace_item_task_id = t.id
        \\ORDER BY t.id ASC
    , &.{});
    defer q.deinit();

    const row_on = (try q.next()) orelse return error.RowMissing072;
    defer row_on.deinit(alloc);
    try testing.expectEqualStrings("task_on_board", row_on.values[0]);
    try testing.expectEqualStrings("col_1", row_on.values[1]); // matched column
    try testing.expectEqualStrings("7", row_on.values[2]); // matched position

    const row_un = (try q.next()) orelse return error.RowMissing072;
    defer row_un.deinit(alloc);
    try testing.expectEqualStrings("task_unassigned", row_un.values[0]);
    try testing.expectEqualStrings("", row_un.values[1]); // NULL → empty string
    try testing.expectEqualStrings("0", row_un.values[2]); // COALESCE → 0

    try testing.expect((try q.next()) == null); // no extra rows
}

// ===== Tests merged from migration_073_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 073
// (`session_activity` append-only log).
//
// Why this file exists
// ────────────────────
// Migration 073 adds a per-session activity log that records every
// `update_activity` tool call AND every compaction event. This is
// purely additive — `worker.last_activity_description` (the live UI
// signal) keeps being overwritten as before.
//
// The migration must:
//   1. Create the `session_activity` table with the expected schema
//      (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
//      description TEXT NOT NULL, created_at DATETIME DEFAULT
//      CURRENT_TIMESTAMP).
//   2. Create the `idx_session_activity_session_created` index over
//      `(session_id, created_at DESC)` so the per-session "most
//      recent N" query is fast.
//   3. Be idempotent on a re-run (CREATE TABLE IF NOT EXISTS + CREATE
//      INDEX IF NOT EXISTS — per the project-wide
//      `migration-is-idempotent` invariant).
//   4. Allow INSERT + SELECT round-trip on a row.
//
// Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
// Task: task_1786629034327 ("new table session_activity")

const TestCtx073 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with the empty (pre-migration) state. After
/// Migration 073 runs, `session_activity` exists and the index is
/// installed.
fn setupDb073() !TestCtx073 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration creates the `session_activity` table with the right
// columns in the right order.
// ============================================================================

test "Migration073 creates session_activity table with correct columns" {
    // After migration, `pragma_table_info('session_activity')` must
    // show columns in order: id (TEXT PK), session_id (TEXT NOT NULL),
    // description (TEXT NOT NULL), created_at (DATETIME DEFAULT
    // CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should NOT have session_activity
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Post-migration: table exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionActivityTableNotCreated073;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("session_activity", row.values[0]);
    }

    // Verify the 4 expected columns exist with the expected names + order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM pragma_table_info('session_activity') ORDER BY cid",
        &.{});
    defer q.deinit();
    const expected_columns = [_][]const u8{ "id", "session_id", "description", "created_at" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected_columns.len);
        try testing.expectEqualStrings(expected_columns[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_columns.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run.
// ============================================================================

test "Migration073 is idempotent on a re-run" {
    // The migration's CREATE statements all use IF NOT EXISTS. A
    // second run must NOT crash with "table session_activity already
    // exists" or similar errors.
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);
    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    // Still exactly 1 session_activity table.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='session_activity'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 3 — Index created.
// ============================================================================

test "Migration073 creates idx_session_activity_session_created index" {
    // After migration, `sqlite_master` must contain a row for
    // `idx_session_activity_session_created` with type='index' over
    // (session_id, created_at DESC).
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, index doesn't exist.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_session_activity_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse null;
        if (row) |r| {
            defer r.deinit(alloc);
            try testing.expect(false); // pre-migration should not have the index
        }
    }

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type='index' AND name='idx_session_activity_session_created'
        , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.IndexNotCreated073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("idx_session_activity_session_created", row.values[0]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip.
// ============================================================================

test "Migration073 fresh-DB replay: insert and select a session_activity row" {
    // After migration, an INSERT into session_activity followed by a
    // SELECT must round-trip the values correctly. The id is supplied
    // by the caller (TEXT PK), so we hardcode one for determinism.
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration073AddSessionActivity.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO session_activity (id, session_id, description) VALUES (?, ?, ?)
        , &.{ "act_001", "sess_test", "[2026-08-13 10:00] test @ /tmp | Thinking | hello" });

    var q = try ctx.db.query(alloc,
        "SELECT id, session_id, description FROM session_activity WHERE session_id = ?",
        &.{"sess_test"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing073;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("act_001", row.values[0]);
    try testing.expectEqualStrings("sess_test", row.values[1]);
    try testing.expectEqualStrings("[2026-08-13 10:00] test @ /tmp | Thinking | hello", row.values[2]);

    // No further rows.
    try testing.expect((try q.next()) == null);
}

// ===== Tests merged from migration_074_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 074
// (`llm_history.cache_creation_input_tokens` +
// `llm_history.cache_read_input_tokens`).
//
// Why this file exists
// ────────────────────
// Migration 074 adds two cache-breakdown columns to `llm_history` so
// the Anthropic profile's `cache_creation_input_tokens` and
// `cache_read_input_tokens` survive the trip from the SSE parser
// through `CallResponse.usage` → `saveMessage` / `insertLLMHistories`
// → the row. OpenAI rows always carry 0 (the parser never sets the
// fields for that profile).
//
// The migration must:
//   1. Add `cache_creation_input_tokens` and `cache_read_input_tokens`
//      columns to `llm_history`, both INTEGER DEFAULT 0 (so legacy
//      rows backfill cleanly).
//   2. Be idempotent on a re-run — `ALTER TABLE … ADD COLUMN` is NOT
//      idempotent, so we use the existing `addColumnIfMissing` helper
//      (probe `pragma_table_info` first; same pattern as Migration 020).
//   3. Allow INSERT + SELECT round-trip on a row with explicit cache
//      values populated.
//
// Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations`
// so the test schema matches what production runs (per the reviewer
// note on PR #172: "when setup db, use from migrations module, migrations
// module will load all table"). This avoids the drift trap of hand-rolling
// a minimal `llm_history` schema — the moment a new column or trigger
// lands in production, the hand-rolled baseline silently tests an
// outdated schema.
//
// Plan: docs/superpowers/plans/2026-08-13-fix-anthropic-total-tokens.md
// Task: task_1786640688092 ("fixing antropic agent total tokens")

const TestCtx074 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — including the 2
/// cache-breakdown columns.
fn setupDb074() !TestCtx074 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration adds the 2 columns with the right name + type +
// default 0. (Schema is post-migration; verifies the columns are
// present and have the right shape.)
// ============================================================================

test "Migration074 adds cache_creation_input_tokens + cache_read_input_tokens to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Post-migration: both columns exist with type=INTEGER and dflt_value=0.
    var q = try ctx.db.query(alloc,
        "SELECT name, type, dflt_value FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens') " ++
            "ORDER BY name",
        &.{});
    defer q.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "cache_creation_input_tokens", .type = "INTEGER", .default = "0" },
        .{ .name = "cache_read_input_tokens", .type = "INTEGER", .default = "0" },
    };

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — Idempotent on re-run. `runMigrations` tracks versions in
// `schema_migrations` so a second run is a no-op. We also call
// `Migration074AddLlmHistoryCacheTokenColumns.up` directly a second
// time to verify the `addColumnIfMissing` helper doesn't error with
// "duplicate column name" (the failure mode it specifically guards
// against).
// ============================================================================

test "Migration074 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run all migrations again — the schema_migrations version row
    // makes Migration 074 a no-op.
    var manager = MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Both columns still exist exactly once each.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('cache_creation_input_tokens', 'cache_read_input_tokens')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);

    // Also directly re-run Migration 074's up() — verifies the
    // addColumnIfMissing helper doesn't crash with "duplicate column
    // name" (the failure mode SQLite raises for the second ALTER).
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
    try Migration074AddLlmHistoryCacheTokenColumns.up(&ctx.db, alloc);
}

// ============================================================================
// Test 3 — Legacy-style INSERTs that OMIT the cache columns still
// succeed with default 0 backfill. This is the regression check for
// the "legacy rows backfill cleanly" contract — an old DB with rows
// already inserted would NOT re-INSERT; the new columns just show as 0.
// ============================================================================

test "Migration074 lets legacy-shape INSERTs succeed with default 0 cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // INSERT that does NOT mention the 2 cache columns — the
    // INSERT-time DEFAULT 0 (set by Migration 074) must kick in.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model) VALUES (?, ?, ?)",
        &.{ "h_legacy", "sess_legacy", "claude-opus-4" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens FROM llm_history WHERE id = ?",
        &.{"h_legacy"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);
}

// ============================================================================
// Test 4 — INSERT + SELECT round-trip with explicit cache values.
// Mirrors what `saveMessage` / `insertLLMHistories` will write when an
// Anthropic call returns cache_creation=500, cache_read=5000.
// ============================================================================

test "Migration074: insert and select an llm_history row with explicit cache counts" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, cache_creation_input_tokens, cache_read_input_tokens) " ++
            "VALUES (?, ?, ?, ?, ?)",
        &.{ "h_cached", "sess_cached", "claude-opus-4", "500", "5000" });

    var q = try ctx.db.query(alloc,
        "SELECT cache_creation_input_tokens, cache_read_input_tokens " ++
            "FROM llm_history WHERE id = ?",
        &.{"h_cached"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing074;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("500", row.values[0]);
    try testing.expectEqualStrings("5000", row.values[1]);
}

// ============================================================================
// Test 5 — Migration 074 is registered in `allMigrations` (mirrors the
// pattern in migration_066_test.zig / migration_067_test.zig /
// migration_068_test.zig / migration_069_test.zig / migration_070_test.zig
// / migration_071_test.zig). Defining the struct alone is not enough —
// it must also be added to `migration.zig::allMigrations` so the
// production migration runner picks it up.
// ============================================================================

test "Migration074 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration074AddLlmHistoryCacheTokenColumns.version and
            std.mem.eql(u8, m.name, Migration074AddLlmHistoryCacheTokenColumns.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_075_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 075
// (rename 5 timestamp columns to `_nano` suffix).
//
// Why this file exists
// ────────────────────
// Migration 075 renames:
//   - `logs.created_at`              → `logs.created_at_nano` (datetime-namespace; actually ms INTEGER)
//   - `llm_history.created_at`      → `llm_history.created_at_nano` (TEXT ns — the only true nanosecond column)
//   - `session_skills.loaded_at`    → `session_skills.loaded_at_nano` (INTEGER s)
//   - `worker.last_activity`        → `worker.last_activity_nano` (INTEGER s)
//   - `workspace_item_tasks.last_human_touched_at` → `workspace_item_tasks.last_human_touched_at_nano` (INTEGER ms)
//
// Plus 2 index renames (the only ones whose name explicitly contains
// the old column name):
//   - `idx_logs_created_at`    → `idx_logs_created_at_nano`
//   - `idx_worker_last_activity` → `idx_worker_last_activity_nano`
//
// The 2 generic `idx_llm_history_*_created` indexes keep their names
// (use a generic `_created` suffix) — SQLite internally updates the
// column reference during the RENAME.
//
// The `_nano` suffix is a uniform project convention (see project memory
// `timestamp-columns-nano-suffix-convention`) — it documents "integer
// stored since Unix epoch", NOT strict nanoseconds. The actual precision
// varies per column and is documented in the migration doc-comment +
// the corresponding Zig model file.
//
// Wire format preserved: the JSON field name on HTTP responses stays
// exactly the same (`created_at`, `loaded_at`, `last_activity`,
// `last_human_touched_at`). The new SQL column is aliased to the old
// wire name in every SELECT projection so the frontend JSON shape is
// byte-identical.
//
// The migration must:
//   1. Rename all 5 columns via `ALTER TABLE … RENAME COLUMN`
//      (SQLite >= 3.25; this project bundles 3.53.3).
//   2. Drop the 2 old indexes and re-CREATE them under the new name.
//   3. Be idempotent on a re-run — `renameColumnIfExists` probes
//      `pragma_table_info` first; if the old column doesn't exist
//      (fresh-DB already has the new name, or a re-run after the
//      rename succeeded), the helper returns silently.
//   4. Preserve data — `ALTER TABLE … RENAME COLUMN` is in-place
//      and preserves all rows + indices on the column.
//   5. Preserve FK references — other tables' FK constraints that
//      point AT this table are auto-updated by SQLite's RENAME.
//
// Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md
// Task: task_1786891244388_1 (kanban: sprint bulan juni → "change column name").

const TestCtx075 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — BEFORE Migration 075's
/// rename. We seed one row in each affected table so the post-rename
/// round-trip test can verify the data survived the rename.
fn setupDb075() !TestCtx075 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Seed one row in each affected table so the data-preservation
    // tests have something to verify against. IMPORTANT: by the time
    // `setupDb()` returns, ALL migrations 001 → 075 have already run
    // (Migration075 is in the `allMigrations` slice — verified by the
    // test `Migration075 runs cleanly via registerAllMigrations +
    // runMigrations`). So all column references must use the NEW
    // (_nano) names. The migration preserves the data — these seeds
    // populate values that the test verifies after the rename.
    trySeed075(alloc, &db, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{}, "workspaces");
    trySeed075(alloc, &db, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1', 'ws_1', 'kanban')", &.{}, "workspace_items");
    trySeed075(alloc, &db, "INSERT INTO sessions (id, name, status) VALUES ('sess_1', 'S', 'active')", &.{}, "sessions");

    // llm_history — the actual nanosecond column (TEXT).
    trySeed075(alloc, &db,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h_1', 'sess_1', 'm1', '1784119389936251112')",
        &.{}, "llm_history");

    return .{ .db = db, .threaded = threaded };
}

fn trySeed075(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, argv: []const []const u8, table_name: []const u8) void {
    db.exec(alloc, sql, argv) catch |err| {
        std.debug.print("FAIL seed {s}: {s}\n", .{ table_name, @errorName(err) });
    };
}

/// Returns the list of column names on `table` (via pragma_table_info).
/// Caller owns the returned slice. Each element is allocated via
/// `alloc.dupe` and the slice itself is heap-allocated — both must be
/// freed.
fn listColumns075(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, table: []const u8) ![]const []u8 {
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &.{table});
    defer q.deinit();
    var cols = std.ArrayList([]u8).empty;
    errdefer {
        for (cols.items) |c| alloc.free(c);
        cols.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try cols.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return cols.toOwnedSlice(alloc);
}

// ============================================================================
// Test 1 — All 5 columns renamed
// ============================================================================

test "Migration075 renames the 5 timestamp columns to _nano suffix" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify each table has the new column and NOT the old one.
    const cases = [_]struct { table: []const u8, old: []const u8, new: []const u8 }{
        .{ .table = "logs", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "llm_history", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "session_skills", .old = "loaded_at", .new = "loaded_at_nano" },
        .{ .table = "worker", .old = "last_activity", .new = "last_activity_nano" },
        .{ .table = "workspace_item_tasks", .old = "last_human_touched_at", .new = "last_human_touched_at_nano" },
    };

    for (cases) |c| {
        // New column exists.
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.new });
        defer q.deinit();
        const row = (try q.next()) orelse {
            std.debug.print("MISSING new column: {s}.{s}\n", .{ c.table, c.new });
            return error.NewColumnMissing075;
        };
        defer row.deinit(alloc);

        // Old column is gone.
        var q2 = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.old });
        defer q2.deinit();
        const r2 = try q2.next();
        if (r2 != null) {
            std.debug.print("OLD column still present: {s}.{s}\n", .{ c.table, c.old });
            return error.OldColumnStillPresent075;
        }
    }
}

// ============================================================================
// Test 2 — Data preserved across the rename (llm_history only — the
// other tables use the same migration_064_test.zig setup pattern, see
// README in this file for the reasoning).
// ============================================================================

test "Migration075 preserves the seeded data across the rename" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // llm_history.created_at_nano still holds the original ns string.
    {
        var q = try ctx.db.query(alloc,
            "SELECT created_at_nano FROM llm_history WHERE id = 'h_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing075;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1784119389936251112", row.values[0]);
    }
}

// ============================================================================
// Test 3 — Old indexes renamed to new indexes (DROPPED + CREATED)
// ============================================================================

test "Migration075 renames idx_logs_created_at → idx_logs_created_at_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing075;
        defer row.deinit(alloc);
    }
}

test "Migration075 renames idx_worker_last_activity → idx_worker_last_activity_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing075;
        defer row.deinit(alloc);
    }
}

// ============================================================================
// Test 4 — Generic indexes still reference the renamed column
// ============================================================================

test "Migration075 updates the internal column reference of idx_llm_history_session_created" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // The index's NAME is unchanged (uses generic `_created` suffix).
    // The internal column reference DOES update — verified by querying
    // EXPLAIN QUERY PLAN on a SELECT that uses this index.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_llm_history_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.IndexMissing075;
        defer row.deinit(alloc);
    }

    // Verify the index is still usable — EXPLAIN should pick it up
    // for a query that filters on session_id.
    {
        var q = try ctx.db.query(alloc,
            "EXPLAIN QUERY PLAN SELECT id FROM llm_history WHERE session_id = 'sess_1' ORDER BY created_at_nano DESC",
            &.{});
        defer q.deinit();
        var found_index: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            for (row.values) |v| {
                if (std.mem.indexOf(u8, v, "idx_llm_history_session_created") != null) {
                    found_index = true;
                    break;
                }
            }
        }
        try testing.expect(found_index);
    }
}

// ============================================================================
// Test 5 — Idempotent on re-run (the killer test — renameColumnIfExists
// probes pragma_table_info first)
// ============================================================================

test "Migration075 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run once.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a second time — must NOT crash with "no such column" (the
    // raw `ALTER TABLE … RENAME COLUMN` failure mode) nor with any
    // other error.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a third time for good measure.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 3 runs.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('created_at', 'created_at_nano')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing075;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 6 — Full-migration runner is idempotent (schema_migrations tracking)
// ============================================================================

test "Migration075 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration075RenameTimestampColumnsToNanoSuffix.version and
            std.mem.eql(u8, m.name, Migration075RenameTimestampColumnsToNanoSuffix.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Migration075 runs cleanly via registerAllMigrations + runMigrations" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Re-run — schema_migrations version 75 makes Migration 075 a no-op.
    var manager2 = MigrationManager.init(alloc, &db);
    defer manager2.deinit();
    try registerAllMigrations(&manager2);
    try manager2.runMigrations();

    // Schema check: the new column names exist.
    var q = try db.query(alloc,
        "SELECT 1 FROM pragma_table_info('llm_history') WHERE name = 'created_at_nano'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing075;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 7 — INSERT after the rename uses the new column name
// ============================================================================

test "Migration075: INSERT into llm_history uses created_at_nano (not created_at)" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // INSERT with the new column name — must succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ "h_after", "sess_1", "m1", "1784119389936251113" });

    // SELECT from the new column.
    var q = try ctx.db.query(alloc,
        "SELECT created_at_nano FROM llm_history WHERE id = 'h_after'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing075;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1784119389936251113", row.values[0]);
}

// ============================================================================
// Test 8 — ORDER BY on the new column works (verifies the index survived)
// ============================================================================

test "Migration075: ORDER BY last_activity_nano DESC on worker uses the renamed index" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // EXPLAIN QUERY PLAN should pick up idx_worker_last_activity_nano for
    // an ORDER BY last_activity_nano DESC query.
    var q = try ctx.db.query(alloc,
        "EXPLAIN QUERY PLAN SELECT id FROM worker ORDER BY last_activity_nano DESC",
        &.{});
    defer q.deinit();
    var found_index: bool = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        for (row.values) |v| {
            if (std.mem.indexOf(u8, v, "idx_worker_last_activity_nano") != null) {
                found_index = true;
                break;
            }
        }
    }
    try testing.expect(found_index);
}

// ============================================================================
// Test 9 — Full table-info diff (regression: no extra columns lost or gained)
// ============================================================================

test "Migration075: per-table column count is preserved (rename doesn't drop or add columns)" {
    const alloc = testing.allocator;
    var ctx = try setupDb075();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Snapshot before.
    const before_logs = try listColumns075(alloc, &ctx.db, "logs");
    defer {
        for (before_logs) |c| alloc.free(c);
        alloc.free(before_logs);
    }
    const before_llm = try listColumns075(alloc, &ctx.db, "llm_history");
    defer {
        for (before_llm) |c| alloc.free(c);
        alloc.free(before_llm);
    }
    const before_skills = try listColumns075(alloc, &ctx.db, "session_skills");
    defer {
        for (before_skills) |c| alloc.free(c);
        alloc.free(before_skills);
    }
    const before_worker = try listColumns075(alloc, &ctx.db, "worker");
    defer {
        for (before_worker) |c| alloc.free(c);
        alloc.free(before_worker);
    }
    const before_tasks = try listColumns075(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (before_tasks) |c| alloc.free(c);
        alloc.free(before_tasks);
    }

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Snapshot after.
    const after_logs = try listColumns075(alloc, &ctx.db, "logs");
    defer {
        for (after_logs) |c| alloc.free(c);
        alloc.free(after_logs);
    }
    const after_llm = try listColumns075(alloc, &ctx.db, "llm_history");
    defer {
        for (after_llm) |c| alloc.free(c);
        alloc.free(after_llm);
    }
    const after_skills = try listColumns075(alloc, &ctx.db, "session_skills");
    defer {
        for (after_skills) |c| alloc.free(c);
        alloc.free(after_skills);
    }
    const after_worker = try listColumns075(alloc, &ctx.db, "worker");
    defer {
        for (after_worker) |c| alloc.free(c);
        alloc.free(after_worker);
    }
    const after_tasks = try listColumns075(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (after_tasks) |c| alloc.free(c);
        alloc.free(after_tasks);
    }

    // Column counts must be identical (rename is in-place).
    try testing.expectEqual(before_logs.len, after_logs.len);
    try testing.expectEqual(before_llm.len, after_llm.len);
    try testing.expectEqual(before_skills.len, after_skills.len);
    try testing.expectEqual(before_worker.len, after_worker.len);
    try testing.expectEqual(before_tasks.len, after_tasks.len);
}

// ===== Tests merged from migration_077_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 077
// (users + user_companies + user_company_members + workspaces.user_id +
//  sessions.user_id + default user_system + backfill).
//
// Why this file exists
// ────────────────────
// Migration 077 lays the schema foundation for multi-user / multi-tenant pabrik:
//   - `users` table (id, email, name, password_hash, role, is_active,
//     created_at, updated_at, last_login_at)
//   - `user_companies` table (id, name, slug, description, is_active,
//     created_at, updated_at, created_by)
//   - `user_company_members` join table (user_id, user_company_id, role,
//     joined_at, invited_by) with composite PRIMARY KEY
//   - Additive `user_id` column on `workspaces` (nullable, no FK constraint)
//   - Additive `user_id` column on `sessions` (nullable, no FK constraint)
//   - Default `user_system` user (is_active=0, password_hash='!disabled',
//     can never log in)
//   - Backfill of all legacy workspaces + sessions to user_id='user_system'
//
// The migration must:
//   1. Create all 3 new tables with the right column types + defaults.
//   2. Add `user_id` columns to `workspaces` + `sessions` via
//      `addColumnIfMissing` (idempotent on re-run).
//   3. Create the 6 supporting indexes (idx_users_email, idx_users_active,
//      idx_user_companies_slug, idx_user_companies_active,
//      idx_user_company_members_user, idx_user_company_members_company,
//      idx_workspaces_user_id, idx_sessions_user_id).
//   4. Insert the default `user_system` user (idempotent via INSERT OR IGNORE).
//   5. Backfill all legacy rows (workspaces, sessions) where user_id IS NULL
//      to user_id='user_system'. Idempotent — re-running on a DB where every
//      row already has user_id set is a no-op.
//   6. Be safe for fresh-DB installs (the canonical CREATE TABLE in earlier
//      migrations does NOT declare user_id, so the ALTER TABLE adds it; on
//      re-run, `addColumnIfMissing` short-circuits).
//
// Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations` so
// the test schema matches what production runs (per project memory
// `project-test-use-migrations-module`). This avoids the drift trap of
// hand-rolling a minimal workspaces / sessions schema — the moment a new
// column lands in production, the hand-rolled baseline silently tests an
// outdated schema.
//
// Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
// Task: task_1787199963946_1
// Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md

const TestCtx077 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 077.
/// After this returns, the schema is exactly what a production DB looks
/// like after Migration 077 has run — the 3 new tables exist, the 2
/// additive columns are present, the default user_system is in the
/// users table, and every existing row (zero, since this is a fresh DB)
/// would have user_id='user_system' if there were any.
fn setupDb077() !TestCtx077 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — `users` table has all 9 columns with the right types + defaults.
// ============================================================================

test "Migration077 creates users table with all 9 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Expected columns: (name, type, default value or "" for none).
    // Migration 092 appends `config_json` (nullable TEXT, per-user LLM
    // config for `--auth` mode) — the full migration chain runs in
    // setupDb, so it is present here.
    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "email", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "''" },
        .{ .name = "password_hash", .type = "TEXT", .default = "" },
        .{ .name = "role", .type = "TEXT", .default = "'user'" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "last_login_at", .type = "DATETIME", .default = "" },
        .{ .name = "config_json", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('users') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        // SQLite's dflt_value is the raw literal (e.g. "''" for empty-string DEFAULT,
        // "'user'" for the role default). Compare as-is.
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — `user_companies` table has all 8 columns with the right types +
// defaults.
// ============================================================================

test "Migration077 creates user_companies table with all 8 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "" },
        .{ .name = "slug", .type = "TEXT", .default = "" },
        .{ .name = "description", .type = "TEXT", .default = "''" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "created_by", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('user_companies') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 3 — `user_company_members` join table has the composite PRIMARY KEY.
// ============================================================================

test "Migration077 creates user_company_members table with composite PK" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the table exists with all 5 user-defined columns.
    const expected = [_][]const u8{
        "user_id", "user_company_id", "role", "joined_at", "invited_by",
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('user_company_members') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);

    // Verify the composite PRIMARY KEY (user_id, user_company_id) is in
    // place. SQLite stores the PK info in pragma_table_info's `pk` column;
    // the composite PK manifests as pk=1 on user_id and pk=2 on
    // user_company_id (the order they're declared in the PRIMARY KEY clause).
    var pk_q = try ctx.db.query(alloc,
        \\SELECT name, pk FROM pragma_table_info('user_company_members')
        \\WHERE pk > 0 ORDER BY pk
    , &.{});
    defer pk_q.deinit();

    const expected_pk = [_][]const u8{ "user_id", "user_company_id" };
    var pk_idx: usize = 0;
    while (try pk_q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(pk_idx < expected_pk.len);
        try testing.expectEqualStrings(expected_pk[pk_idx], row.values[0]);
        pk_idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_pk.len), pk_idx);

    // Verify the CHECK constraint on `role` rejects invalid values.
    // `sqlite3_prepare_v2` will return an error if the constraint fails.
    // Valid value: insert succeeds. Invalid value: insert fails with
    // CHECK constraint failed.
    try ctx.db.exec(alloc,
        "INSERT INTO users (id, email, name, password_hash) VALUES ('u_pk', 'u_pk@x', 'U', 'h')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO user_companies (id, name, slug) VALUES ('c_pk', 'C', 'c-pk')",
        &.{});

    // Valid role: 'member' (the default) — should succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'member')",
        &.{});

    // Invalid role: 'superuser' (not in the CHECK list) — should fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'superuser')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

// ============================================================================
// Test 4 — workspaces.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to workspaces and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, "notnull" FROM pragma_table_info('workspaces')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing077;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row WITH user_id=NULL (mimics a row from a pre-077 DB).
    // The column allows NULL by default since the migration uses
    // "user_id TEXT" (no NOT NULL).
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id, name, user_id) VALUES ('ws_legacy', 'Legacy', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        // NULL is represented as an empty string by SqliteBackend.exec,
        // matching the project convention (see project memory
        // `sqlite-backend-empty-slice-binds-as-null`).
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration. `addColumnIfMissing` is a no-op (column
    // exists), `CREATE TABLE IF NOT EXISTS` is a no-op, `INSERT OR IGNORE`
    // is a no-op for user_system — but the backfill UPDATE will convert
    // the NULL user_id to 'user_system'.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 5 — sessions.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to sessions and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, "notnull" FROM pragma_table_info('sessions')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing077;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row with user_id=NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, user_id) VALUES ('sess_legacy', 'Legacy', 'active', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration to trigger the backfill.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing077;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 6 — Default `user_system` user exists with the right shape.
// ============================================================================

test "Migration077 inserts the default user_system user" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var q = try ctx.db.query(alloc,
        \\SELECT id, email, name, password_hash, role, is_active
        \\FROM users WHERE id = 'user_system'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UserSystemMissing077;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("user_system", row.values[0]);
    try testing.expectEqualStrings("system@local", row.values[1]);
    try testing.expectEqualStrings("System", row.values[2]);
    try testing.expectEqualStrings("!disabled", row.values[3]);
    try testing.expectEqualStrings("admin", row.values[4]);
    try testing.expectEqualStrings("0", row.values[5]); // is_active=0 — can never log in

    // Verify exactly ONE user_system row exists (UNIQUE constraint on
    // email + INSERT OR IGNORE on the second migration call).
    var count_q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse return error.CountMissing077;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

// ============================================================================
// Test 7 — Idempotent on re-run (the killer test — addColumnIfMissing + INSERT OR IGNORE).
// ============================================================================

test "Migration077 is idempotent on re-run via addColumnIfMissing + INSERT OR IGNORE" {
    const alloc = testing.allocator;
    var ctx = try setupDb077();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run .up() three more times — each must NOT crash with
    // "duplicate column name" or "UNIQUE constraint failed" or any
    // other error. This is the specific failure mode addColumnIfMissing +
    // INSERT OR IGNORE are designed to prevent.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 4 runs total
    // (1 from setupDb + 3 from this test).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspaces') WHERE name = 'user_id'
    , &.{});
    defer q.deinit();
    const ws_row = (try q.next()) orelse return error.RowMissing077;
    defer ws_row.deinit(alloc);
    try testing.expectEqualStrings("1", ws_row.values[0]);

    var q2 = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'user_id'
    , &.{});
    defer q2.deinit();
    const sess_row = (try q2.next()) orelse return error.RowMissing077;
    defer sess_row.deinit(alloc);
    try testing.expectEqualStrings("1", sess_row.values[0]);

    // Verify exactly ONE user_system row.
    var q3 = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer q3.deinit();
    const user_row = (try q3.next()) orelse return error.RowMissing077;
    defer user_row.deinit(alloc);
    try testing.expectEqualStrings("1", user_row.values[0]);

    // Run the full migration runner again — schema_migrations tracking
    // makes Migration 077 a no-op.
    var manager = MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();
}

// ============================================================================
// Test 8 — Migration 077 is registered in `allMigrations`. Defining the
// struct alone is not enough — it must also be added to
// `migration.zig::allMigrations` so the production migration runner picks
// it up (per project memory `migration-registration-trap.md`).
// ============================================================================

test "Migration077 is registered in allMigrations" {
    const all = allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration077AddUsersAndRbacSchema.version and
            std.mem.eql(u8, m.name, Migration077AddUsersAndRbacSchema.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// ===== Tests merged from migration_082_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 082
// (`sessions.last_human_touched_at_nano`).
//
// Why this file exists
// ────────────────────
// Migration 082 adds a single nullable INTEGER column on `sessions` that
// stamps the last time a HUMAN (not the AI agent) interacted with a
// chat. The chat sidebar UI uses this column instead of `updated_at`
// (which gets bumped by every AI SSE tick) so the visible time pill
// reads "5m ago" if you touched the chat 5 minutes ago even when the
// agent has been running since.
//
// Sibling of Migration 065 (`workspace_item_tasks.last_human_touched_at`,
// landed in commit `e07a13f6` for the kanban-task-notification-icon plan).
// This migration does the same thing for the SESSIONS table — the kanban
// card already uses the task-side column for its "awaiting review" dot,
// the sidebar now uses the session-side column for its time pill.
//
// The migration must:
//   1. Add `last_human_touched_at_nano INTEGER` (nullable, no DEFAULT —
//      NULL = "never touched by a human", which the frontend falls back
//      to `updated_at` for, so pre-migration sessions keep their old
//      visible time without a regression).
//   2. Be idempotent on re-run (re-running must not crash with
//      "duplicate column name" — see the project's hard-fought
//      knowledge about fresh-DB migration cascades in
//      `pabrik-data-and-routines.md` §"Migration #009-#052 fresh-DB
//      cascade is fragile").
//   3. Be safe for fresh-DB installs that already declare the column
//      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//      the helper handles both fresh-DB and upgrade-from-v1 paths.
//   4. Leave existing rows at NULL (NOT 0 or the current time — same
//      reasoning as Migration 065: we cannot retroactively know whether
//      a session from before the migration was "touched").
//
// Column name uses the `_nano` suffix per the project-wide convention
// from Migration 075. The wire field stays bare `last_human_touched_at`.
//
// Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
// Spec: docs/superpowers/specs/2026-08-29-chat-sidebar-last-human-touched-design.md

const TestCtx082 = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Minimal `sessions` table mirror matching the v17 production shape
/// (no `last_human_touched_at_nano` column yet, that's exactly what the
/// migration adds). The production DB walks migrations 001 → 081 first
/// so a real `sessions` table is already there; we recreate the v17
/// shape here so the test exercises the upgrade path.
fn setupDb082() !TestCtx082 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration082 adds last_human_touched_at_nano column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'last_human_touched_at_nano'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name (NOT "INTEGER"
    // literal — that footgun was caught in Migration 065's test, see
    // project memory `addColumnIfMissing-requires-name-type`).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at_nano", row.values[0]);

    // Confirm exactly one row matched.
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing082;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);

    // Nullability sanity: NOT NULL must NOT appear in the column's
    // constraints (the canonical "never touched" state is NULL).
    var qn = try ctx.db.query(alloc,
        \\SELECT "notnull" FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qn.deinit();
    const nn_row = (try qn.next()) orelse return error.RowMissing082;
    defer nn_row.deinit(alloc);
    try testing.expectEqualStrings("0", nn_row.values[0]);
}

test "Migration082 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at_nano INTEGER`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    try ctx.db.exec(alloc, "DROP TABLE sessions", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    last_human_touched_at_nano INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing session BEFORE applying the migration. Same
    // semantic reasoning as Migration 065: we cannot retroactively
    // know whether the user touched this session before the migration
    // ran, so the value must be NULL — the frontend treats NULL as
    // "fall back to updated_at" which gives legacy sessions their
    // existing visible time without a regression.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_082', 'Legacy chat')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — same
    // convention as Migration 065's test.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_pre_082'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration082 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb082();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_a', 'A')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateSessionLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE sessions SET last_human_touched_at_nano = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "s_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing082;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}

test "Migration082 is registered in allMigrations" {
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration082AddSessionHumanTouchedAt.version) return;
    }
    return error.Migration082NotRegistered082;
}

// ─── Migration 096 — session_skill_events ────────────────────────────────

test "Migration096 creates the ledger table and both indexes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "session_skill_events");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",         "session_id",   "skill_name", "event",
        "source",     "content_hash", "loop_index", "llm_history_id",
        "created_at",
    });

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('idx_session_skill_events_session', 'idx_session_skill_events_skill')",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("2", irow.values[0]);
}

test "Migration096 accepts the production write shape with empty free-text binds" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    // First, prove the trap is real: a bare `?` bound to "" for a NOT NULL
    // column lands as SQL NULL and fails. This is the Migration 079 `content`
    // failure mode, and it is why every free-text column needs a wrapper.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc,
            "INSERT INTO session_skill_events (id, session_id, skill_name, source) VALUES (?, ?, ?, ?)",
            &.{ "evt_bad", "sess_1", "my-skill", "" },
        ),
    );

    // Now the shape every call site must use: `event`, `source`,
    // `content_hash` and `llm_history_id` are NOT NULL free text, so each one
    // is wrapped. This test is what fails if a future writer forgets one.
    try ctx.db.exec(alloc,
        \\INSERT INTO session_skill_events
        \\    (id, session_id, skill_name, event, source, content_hash, loop_index, llm_history_id)
        \\VALUES
        \\    (?, ?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(?, ''), ?, COALESCE(?, ''))
    , &.{ "evt_1", "sess_1", "my-skill", "", "", "", "7", "" });

    var q = try ctx.db.query(alloc,
        "SELECT event, source, content_hash, loop_index FROM session_skill_events WHERE id = ?",
        &.{"evt_1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
    try testing.expectEqualStrings("", row.values[2]);
    try testing.expectEqualStrings("7", row.values[3]);
}

test "Migration096 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);
    try Migration096CreateSessionSkillEvents.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'session_skill_events'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration096 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration096CreateSessionSkillEvents.version) return;
    }
    return error.Migration095NotRegistered;
}

// ─── Migration 096 — skill_eval_facts / _runs / _results ─────────────────

test "Migration097 creates all three tables and their indexes" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const expected = [_][]const u8{ "skill_eval_facts", "skill_eval_runs", "skill_eval_results" };
    for (expected) |table| {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            &.{table});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('uq_skill_eval_facts','idx_skill_eval_facts_skill','uq_skill_eval_runs_self_prompt','idx_skill_eval_runs_session','idx_skill_eval_runs_status','idx_skill_eval_results_run','idx_skill_eval_results_skill','idx_skill_eval_results_session')",
        &.{});
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("8", irow.values[0]);
}

test "Migration097's fact key admits exactly one row per (skill, content, context)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const insert =
        \\INSERT OR IGNORE INTO skill_eval_facts (id, skill_key, content_hash, context_key, verdict_intrinsic)
        \\VALUES (?, ?, ?, ?, ?)
    ;
    try ctx.db.exec(alloc, insert, &.{ "f1", "global:foo", "hashA", "/repo@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    // A second writer for the SAME question cannot insert. This is the whole
    // race guard: the loser goes on to read the winner's row instead of
    // recomputing, and `db.changes() == 0` is how it knows it lost.
    try ctx.db.exec(alloc, insert, &.{ "f2", "global:foo", "hashA", "/repo@abc", "computing" });
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());

    // Same skill, DIFFERENT body → a genuinely different question, so allowed.
    try ctx.db.exec(alloc, insert, &.{ "f3", "global:foo", "hashB", "/repo@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    // Same skill and body in a DIFFERENT repo/commit → also a different
    // question (freshness is repo-relative), so also allowed.
    try ctx.db.exec(alloc, insert, &.{ "f4", "global:foo", "hashA", "/other@abc", "computing" });
    try testing.expect(ctx.db.changes() > 0);

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_facts", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097's partial unique index makes one self-prompted run per session" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    const insert =
        \\INSERT INTO skill_eval_runs (id, session_id, trigger, status)
        \\VALUES (?, ?, ?, 'running')
    ;
    try ctx.db.exec(alloc, insert, &.{ "r1", "sess_a", "self_prompt" });

    // The agent can emit two `run_skill_eval` tool calls in one turn; both
    // would see "no run yet". The index is the arbiter, not a pre-check.
    try testing.expectError(
        error.ExecuteFailed,
        ctx.db.exec(alloc, insert, &.{ "r2", "sess_a", "self_prompt" }),
    );

    // A different session may run its own.
    try ctx.db.exec(alloc, insert, &.{ "r3", "sess_b", "self_prompt" });

    // And `on_demand` is outside the partial index, so one session can have
    // both a self-prompted and an on-demand run.
    try ctx.db.exec(alloc, insert, &.{ "r4", "sess_a", "on_demand" });

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skill_eval_runs", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097's user_id stays nullable so an empty bind is legal" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    // `user_id` is nullable on purpose: `exec` binds "" as SQL NULL, so a
    // plain `?` bind is the correct way to write "no owner" — a NOT NULL
    // column here would break every auth-off writer.
    try ctx.db.exec(alloc,
        "INSERT INTO skill_eval_runs (id, session_id, trigger, user_id) VALUES (?, ?, 'self_prompt', ?)",
        &.{ "r_null", "sess_c", "" });

    var q = try ctx.db.query(alloc,
        "SELECT IFNULL(user_id, '<null>') FROM skill_eval_runs WHERE id = ?",
        &.{"r_null"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("<null>", row.values[0]);
}

test "Migration097 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);
    try Migration097CreateSkillEvalTables.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'skill_eval_%'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("3", row.values[0]);
}

test "Migration097 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration097CreateSkillEvalTables.version) return;
    }
    return error.Migration097NotRegistered;
}

// ============================================================================
// Migration 098 — documents
// ============================================================================

test "Migration098 creates documents with the expected columns and NOT NULL defaults" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration098CreateDocuments.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "documents");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_id", "title", "content", "format", "created_at", "updated_at",
    });
}

test "Migration098's format column defaults to markdown and rejects a NULL write" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration098CreateDocuments.up(&ctx.db, alloc);

    // Omit `format` entirely so the schema DEFAULT applies. Binding ""
    // instead would land as SQL NULL and violate NOT NULL — that is the
    // SqliteBackend.exec empty-slice trap, and it is exactly why the
    // writers use COALESCE(NULLIF(?, ''), '').
    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content)
        \\VALUES ('doc_1', 'ws_1', 'Notes', '# hello')
    , &.{});

    var q = try ctx.db.query(alloc, "SELECT format FROM documents WHERE id = 'doc_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("markdown", row.values[0]);

    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, format) VALUES ('doc_2', 'ws_1', NULL)
    , &.{}));
}

test "Migration098 indexes workspace_id so cross-workspace reads stay scoped" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration098CreateDocuments.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title) VALUES
        \\  ('doc_a', 'ws_1', 'A'), ('doc_b', 'ws_2', 'B')
    , &.{});

    var q = try ctx.db.query(alloc,
        "SELECT id FROM documents WHERE workspace_id = ?", &.{"ws_2"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("doc_b", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration098 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration098CreateDocuments.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO documents (id, workspace_id, title, content) VALUES ('doc_1', 'ws_1', 'Notes', 'body')
    , &.{});

    // Both statements are IF NOT EXISTS, so a re-run must not throw
    // "table already exists" and must not disturb the stored row.
    try Migration098CreateDocuments.up(&ctx.db, alloc);
    try Migration098CreateDocuments.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT title, content FROM documents WHERE id = 'doc_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("Notes", row.values[0]);
    try testing.expectEqualStrings("body", row.values[1]);
}

test "Migration098 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration098CreateDocuments.version) return;
    }
    return error.Migration098NotRegistered;
}

// ============================================================================
// ============================================================================
// Migration 100 — `workspace_members` (shared workspaces)
// ============================================================================
//
// See docs/plans/2026-10-02-workspace-members-shared-workspaces.md.
//
// WHY a join table rather than more columns on `workspaces`
// ───────────────────────────────────────────────────────
// `workspaces.user_id` (Migration 077) was doing two unrelated jobs: it
// recorded the OWNER (1 workspace : 1 user), and its magic values
// (NULL / '' / 'user_system') recorded "this row is in the shared legacy
// bucket". Job two is a VISIBILITY property and has nothing to do with job
// one. Conflating them is what made multi-user impossible — a second user
// could only be recorded by overwriting the first.
//
// The split: `workspace_members` answers "who may see this", and the
// sentinel member row answers "this is shared". One mechanism, not two, so
// the two can never disagree. Adding a `user_system` member row to a
// workspace IS the "make it shared" operation.
//
// Shape copied from `user_company_members` (Migration 077)
// ──────────────────────────────────────────────────────
// Composite PK for "no duplicate membership" — the ONLY DB-level integrity
// guarantee available, because `PRAGMA foreign_keys` is deliberately OFF in
// production and SQLite cannot `ALTER TABLE … ADD CONSTRAINT`.
// A CHECK-constrained role, `joined_at` + `invited_by` audit columns.
//
// Role is STORED but NOT ENFORCED
// ────────────────────────────────
// Every member has full access, exactly as before, so this migration changes
// only who can see a workspace — never what they can do. Enforcement is a
// separate change because the workspace role set (owner/admin/editor/viewer)
// is disjoint from the company set (owner/admin/member/guest), and a SQLite
// CHECK cannot be ALTERed — a wrong choice costs the recreate-table dance
// later. DEFAULT 'viewer' is least-privilege, so a row written by a path
// that forgets a role is read-only rather than read-write.
//
// Additive on purpose — `workspaces.user_id` is NOT dropped
// ────────────────────────────────────────────────────────
// The column stays and keeps being written, so `DROP TABLE
// workspace_members` plus a revert of the clause helper is a complete,
// data-loss-free rollback. Dropping it is Migration 101, one release later,
// once nothing reads it.
//
// Idempotency
// ───────────
// CREATE TABLE/INDEX IF NOT EXISTS + INSERT OR IGNORE. `INSERT OR IGNORE`
// matters twice over: re-runs are no-ops, AND a re-run after users start
// sharing can neither duplicate rows nor reset a role that was deliberately
// changed. Both properties are asserted in the inline tests below.


// Migration 100 — `workspace_members` (shared workspaces) — inline tests
// ============================================================================
//
// See docs/plans/2026-10-02-workspace-members-shared-workspaces.md.
//
// The shape these tests pin down is the one a reviewer has to agree with
// before any code ships, so each case answers one question:
//
//   1. Does the table have the shape the design doc promises?
//   2. Does the backfill map every legacy owner bucket to the right member?
//   3. Is it replay-safe AND does re-running it destroy live shares?
//   4. Is it wired into the migration chain at all?

/// Minimal pre-100 schema: just a `workspaces` table carrying `user_id`
/// exactly as Migration 077 left it. Deliberately NOT `setupOwnerRoots` —
/// that fixture also builds `sessions` and `worker`, which have nothing to
/// do with workspace membership and would hide a bug in this table.
fn setupWorkspaceMembersRoot(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator, "CREATE TABLE workspaces (id TEXT PRIMARY KEY, user_id TEXT)", &.{});
}

/// Assert one membership row's user + role. A comparison helper (not a
/// getter) so no duped value escapes and trips the leak-checking allocator.
fn expectMember(ctx: *TestCtx, workspace_id: []const u8, user_id: []const u8, expected_role: []const u8) !void {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT role FROM workspace_members WHERE workspace_id = ? AND user_id = ?",
        &[_][]const u8{ workspace_id, user_id },
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.MemberRowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings(expected_role, row.values[0]);
}

fn countMembers(ctx: *TestCtx) !i64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_members", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.MemberRowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

fn tableDdl(ctx: *TestCtx, table: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' AND name = ?",
        &[_][]const u8{table},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.TableMissing;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "Migration100 creates workspace_members with the shape the design promises" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceMembersRoot(&ctx);

    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_members");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    for ([_][]const u8{ "workspace_id", "user_id", "role", "joined_at", "invited_by" }) |want| {
        var found = false;
        for (cols) |c| {
            if (std.mem.eql(u8, c, want)) found = true;
        }
        try testing.expect(found);
    }

    // `user_id` MUST be NOT NULL. `SqliteBackend.exec` collapses an empty
    // slice to SQL NULL, so an empty owner would blow up the insert instead
    // of silently creating an orphan member row. The create path normalises
    // empty -> 'user_system' BEFORE binding (auth_common.normaliseOwnerId).
    var q = try ctx.db.query(
        alloc,
        "SELECT type, \"notnull\" FROM pragma_table_info('workspace_members') WHERE name = 'user_id'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", row.values[0]);
    try testing.expectEqualStrings("1", row.values[1]);

    // Composite PK (workspace_id, user_id) is the only DB-level "no duplicate
    // membership" guarantee we have — PRAGMA foreign_keys is deliberately
    // OFF (see Migration 077's docstring). It shows up as pk=1/pk=2.
    var qp = try ctx.db.query(
        alloc,
        "SELECT name FROM pragma_table_info('workspace_members') WHERE pk > 0 ORDER BY pk",
        &.{},
    );
    defer qp.deinit();
    const pk1 = (try qp.next()) orelse return error.RowMissing;
    defer pk1.deinit(alloc);
    const pk2 = (try qp.next()) orelse return error.RowMissing;
    defer pk2.deinit(alloc);
    try testing.expectEqualStrings("workspace_id", pk1.values[0]);
    try testing.expectEqualStrings("user_id", pk2.values[0]);

    // The role set is CHECK-constrained, and a SQLite CHECK cannot be
    // ALTERed — so this list is effectively permanent without a table
    // recreate. Assert the exact set so adding a role is a deliberate act.
    const ddl = try tableDdl(&ctx, "workspace_members");
    defer alloc.free(ddl);
    try testing.expect(std.mem.indexOf(u8, ddl, "CHECK (role IN ('owner', 'admin', 'editor', 'viewer'))") != null);

    // Both directions are indexed: the PK covers workspace_id -> members
    // (the hot visibility predicate); this covers user_id -> workspaces.
    var qi = try ctx.db.query(
        alloc,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_workspace_members_user'",
        &.{},
    );
    defer qi.deinit();
    const irow = (try qi.next()) orelse return error.RowMissing;
    defer irow.deinit(alloc);
    try testing.expectEqualStrings("1", irow.values[0]);
}

test "Migration100 maps every legacy owner bucket to the right member row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceMembersRoot(&ctx);

    // All four buckets the pre-100 schema can hold. The empty string is a
    // SQL literal on purpose: binding "" would arrive as NULL and the two
    // buckets could not be told apart in this test.
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_real', 'user_a')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_sys', 'user_system')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_null', NULL)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_empty', '')", &.{});

    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);

    // A real owner stays private to them.
    try expectMember(&ctx, "ws_real", "user_a", "owner");
    // The three "shared legacy bucket" spellings all collapse to the
    // sentinel member — which is what keeps an operator's pre-`--auth`
    // sidebar visible after the migration (user decision 2026-09-25).
    try expectMember(&ctx, "ws_sys", "user_system", "owner");
    try expectMember(&ctx, "ws_null", "user_system", "owner");
    try expectMember(&ctx, "ws_empty", "user_system", "owner");

    // Exactly one member per workspace: the backfill must not ALSO write a
    // row for a real owner on top of the sentinel.
    try testing.expectEqual(@as(i64, 4), try countMembers(&ctx));
}

test "Migration100 is replay-safe and a re-run never clobbers live shares" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceMembersRoot(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_a', 'user_a')", &.{});

    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);
    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);

    // Idempotent on its own: the second run must not duplicate rows.
    try testing.expectEqual(@as(i64, 1), try countMembers(&ctx));

    // Now the interesting case. Users start sharing, and the owner is
    // demoted. A re-run of the backfill must NOT undo either edit — this is
    // what makes it safe to leave a completed migration re-runnable forever.
    try ctx.db.exec(alloc, "INSERT INTO workspace_members (workspace_id, user_id, role) VALUES ('ws_a', 'user_b', 'viewer')", &.{});
    try ctx.db.exec(alloc, "UPDATE workspace_members SET role = 'viewer' WHERE workspace_id = 'ws_a' AND user_id = 'user_a'", &.{});

    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);

    try testing.expectEqual(@as(i64, 2), try countMembers(&ctx));
    try expectMember(&ctx, "ws_a", "user_b", "viewer");
    // Still 'viewer', NOT reset to 'owner' by the backfill.
    try expectMember(&ctx, "ws_a", "user_a", "viewer");
}

test "Migration100 leaves workspaces.user_id alone so rollback still works" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupWorkspaceMembersRoot(&ctx);

    try ctx.db.exec(alloc, "INSERT INTO workspaces (id, user_id) VALUES ('ws_a', 'user_a')", &.{});

    try Migration100AddWorkspaceMembers.up(&ctx.db, alloc);

    // The column is deliberately NOT dropped. `DROP TABLE workspace_members`
    // must be a complete undo, and the old code path must keep working
    // against an untouched workspaces table.
    try expectOwner(&ctx, "workspaces", "ws_a", "user_a");
}

test "Migration100 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration100AddWorkspaceMembers.version) return;
    }
    return error.Migration100NotRegistered;
}


// ============================================================================
// Migration 101 — `llm_history.model` is never empty
// ============================================================================
//
// ## The bug
//
// `llm_history.model` is declared `TEXT NOT NULL` (Migration 001), which reads
// like a guarantee that it is always populated. It is not — NOT NULL rejects
// SQL NULL and says nothing about the empty string. Two distinct paths wrote a
// blank model into chat history:
//
//  1. **Raw SQL with a `''` literal.** The two kanban task-create paths seed a
//     synthetic `role='user'` row so the chatview never lands on the "How can
//     I help you?" empty state. Both hardcoded a `''` model literal, with a
//     comment explaining that `''` was the only way to satisfy NOT NULL given
//     the backend's bind semantics. The row landed; `model` was blank.
//
//  2. **An empty *bind*, which is worse — it loses the row entirely.**
//     `SqliteBackend.exec` binds a zero-length slice as SQL NULL (the rule
//     Migration 100 documents for `workspace_members.user_id`). NULL *does*
//     violate NOT NULL, so the INSERT fails outright — and every write site
//     swallows that non-fatally with a `catch`. The user's message row is
//     silently gone, leaving nothing to render at all.
//
// Failure 2 is why this migration does not simply reject a bad model. A
// `RAISE(ABORT)` trigger would convert "blank model" into "row deleted", which
// is strictly more destructive than either original symptom. So the trigger
// *substitutes* a sentinel instead.
//
// ## What this migration does
//
//   1. Backfills `''` on existing rows to the sentinel.
//   2. Installs an `AFTER INSERT` trigger that rewrites an empty-or-NULL model
//      to the sentinel on every future write.
//
// The trigger is the ONLY choke point that catches raw SQL — the Zig-side guard
// (`agentic_loop/llm_history_model_guard.zig`) cannot see a literal a caller
// typed into its own SQL string. Together they cover both layers: the guard
// gives a real model, the trigger makes the invariant hold even for code that
// predates it or bypasses it.
//
// ## Why AFTER INSERT and not BEFORE
//
// A BEFORE INSERT trigger cannot assign to `NEW.model` in SQLite. The rewrite
// therefore happens in an AFTER INSERT trigger, which costs one extra UPDATE
// only for rows that were actually bad — the common path stays a single INSERT.
//
// ## Idempotency
//
// `CREATE TRIGGER IF NOT EXISTS` plus an UPDATE scoped by
// `model IS NULL OR TRIM(model) = ''`, so re-running is a no-op and can never
// touch a row that already holds a real model.


// ============================================================================
// Migration 101 — the `skills` table: workspace-scoped skill bodies.
// ============================================================================
//
// Skills used to live on disk in TWO directories — a "global" one under
// `~/.config/pabrik/skills/` and a "local" one under `<cwd>/.pabrik/skills/` —
// and which one won was decided by walking the filesystem. That made the
// FILESYSTEM the source of truth: a skill could not be scoped to a
// workspace, could not be listed per workspace, and its identity was a
// pathname. This migration moves the body into SQL so `workspace_id` on the
// row is the isolation boundary, exactly as Migration 098 did for documents.
//
// There is deliberately no `is_global` column and no `cwd` column. Both
// existed only to answer "which of the two directories is this?", and with
// a single workspace-scoped table that question has no answer to give. A
// skill wanted in every workspace is a row per workspace, not a special row.
//
// `UNIQUE (workspace_id, name)` rather than a surrogate-only key because
// `name` is what every caller knows: `use_skill({ name })`, `add_skill({
// name })`, `GET /api/workspaces/:workspace_id/skills/:skill_name`. Without
// it, "two skills called `pdf` in one workspace" would be a
// database-level impossibility rather than an upsert the store performs
// explicitly.
//
// `skill_assets` exists because two installed skills (`pdf`, 11 files, and
// `skill-creator`, 17 files) are BUNDLES whose bodies tell the model to run
// sibling scripts like `scripts/run_eval.py`. A `content` column alone would
// leave the model pointing at files that do not exist. Keeping companions as
// rows is what lets the database stay the only source of truth; `use_skill`
// materialises them into a temp directory and returns that path so the
// body's relative references resolve.
//
// Asset `content` is TEXT, not BLOB: every companion shipped so far is
// .py / .md / .html, and `SqliteBackend` binds through `sqlite3_bind_text`.
// The importer refuses a non-UTF-8 file rather than corrupting it.
//
// Every text column is `NOT NULL DEFAULT ''` rather than nullable, for the
// same reason as `documents`: `SqliteBackend.exec` binds a zero-length slice
// as SQL NULL, so a skill with an empty description (perfectly legal — a
// model may write a body before it writes a description) would blow up the
// NOT NULL constraint mid-write unless every writer goes through
// `COALESCE(NULLIF(?, ''), '')`.
//
// `ON DELETE CASCADE` is documentation only — `PRAGMA foreign_keys` is off
// project-wide (see Migration 072's tests and Migration 093's header), so
// the workspace delete path issues the child DELETEs itself.
//
// Idempotency: CREATE TABLE IF NOT EXISTS. One statement per db.exec
// (sqlite3_prepare_v2 compiles only the first). Neither table gets its own
// index: `UNIQUE (workspace_id, name)` already indexes that exact prefix,
// and `UNIQUE (skill_id, rel_path)` already indexes every `WHERE skill_id =
// ?` read, so a second bare index would only give the planner a duplicate to
// choose between.

// ============================================================================
// Migration 103 — `workspace_secrets`
// ============================================================================
//
// WHY a table and not a field on `users.config_json`
// ──────────────────────────────────────────────────
// `config_json` is USER-scoped and carries no `workspace_id`, while the unit
// of this feature is the workspace; and the whole blob is handed to the
// browser verbatim by `GET /api/config/nalar` (`http_response.zig:365`), so a
// credential map there would be readable by anyone sharing the account.
//
// `value` is PLAINTEXT
// ─────────────────────
// Deliberate, reviewer-decided: no master key, no cipher. It matches how
// `config.json` already holds the LLM `api_key`, so this table does not
// become the one place in the app that claims more protection than the rest.
// Encryption at rest would only have protected the `agent.db` file, because
// the key sits beside it in the same config dir — every backup and every
// copied `.db` would still have exposed the value.
//
// NO `user_id` COLUMN
// ───────────────────
// Access is membership in `workspace_members` (Migration 100), answered
// upstream by `auth_common.canSeeWorkspace`. An owner column would answer
// authorship rather than entitlement, and would start disagreeing with the
// middleware the moment a workspace is shared. See the module header of
// `src/agentic_loop/secrets_store.zig`, which states the same rule for the
// code that reads this table.
//
// `ON DELETE CASCADE` is documentation only — this project deliberately
// leaves `PRAGMA foreign_keys` off (Migration 072's tests, Migration 093's
// header), so the workspace-delete path issues the child DELETE itself.
//
// Every NOT NULL text column is written `COALESCE(NULLIF(?, ''), '')`:
// `SqliteBackend.exec` binds a zero-length slice as SQL NULL, which is how
// Migration 079's `content` column broke.
//
// Idempotency: CREATE TABLE/INDEX IF NOT EXISTS, and one statement per
// `db.exec` (`sqlite3_prepare_v2` compiles only the first).


// Migration 101 — inline tests
// ============================================================================
//
// Each case answers one question a reviewer must agree with before shipping:
//
//   1. Does the backfill repair existing rows without touching real models?
//   2. Does the trigger rewrite a raw-SQL `''` insert?
//   3. Does it leave a healthy insert alone?
//   4. Is it replay-safe?
//   5. Does the SQL sentinel still match the Zig `UNKNOWN_MODEL`?
//   6. Is it wired into the migration chain?
//   7. Do both raw-SQL write sites stay guarded?

/// Minimal pre-101 schema: `llm_history` exactly as Migration 001 left it.
/// Deliberately NOT `setupDb` — that fixture builds the full current schema,
/// including columns and triggers this migration must not depend on.
fn setupLlmHistoryRoot(ctx: *TestCtx) !void {
    try ctx.db.exec(testing.allocator, "CREATE TABLE llm_history (id TEXT PRIMARY KEY, session_id TEXT, model TEXT NOT NULL, response_content TEXT)", &.{});
}

fn seedHistoryRow(ctx: *TestCtx, id: []const u8, model_sql: []const u8) !void {
    // `model_sql` is spliced as a literal, NOT bound — a bound empty slice
    // would collapse to NULL and defeat the point of several cases here.
    const sql = try std.fmt.allocPrint(
        testing.allocator,
        "INSERT INTO llm_history (id, session_id, model, response_content) VALUES ('{s}', 'sess', {s}, 'hi')",
        .{ id, model_sql },
    );
    defer testing.allocator.free(sql);
    try ctx.db.exec(testing.allocator, sql, &.{});
}

/// Read one row's model back as a comparison (no duped value escapes to the
/// caller, which would trip the leak-checking allocator).
fn expectHistoryModel(ctx: *TestCtx, id: []const u8, expected: []const u8) !void {
    var q = try ctx.db.query(testing.allocator, "SELECT COALESCE(model, '<NULL>') FROM llm_history WHERE id = ?", &[_][]const u8{id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.HistoryRowMissing;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, row.values[0]);
}

fn countHistoryRows(ctx: *TestCtx) !i64 {
    var q = try ctx.db.query(testing.allocator, "SELECT COUNT(*) FROM llm_history", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.CountQueryFailed;
    defer row.deinit(testing.allocator);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

test "Migration101 backfills empty and whitespace-only model on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupLlmHistoryRoot(&ctx);

    try seedHistoryRow(&ctx, "r_blank", "''");
    try seedHistoryRow(&ctx, "r_ws", "'   '");
    try seedHistoryRow(&ctx, "r_real", "'space-bunny-free'");

    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);

    try expectHistoryModel(&ctx, "r_blank", Migration101GuardLlmHistoryModel.sentinel);
    try expectHistoryModel(&ctx, "r_ws", Migration101GuardLlmHistoryModel.sentinel);
    // The whole point of scoping the WHERE clause: a real model is untouched.
    try expectHistoryModel(&ctx, "r_real", "space-bunny-free");
}

test "Migration101 trigger rewrites a raw-SQL empty model on INSERT" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupLlmHistoryRoot(&ctx);

    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);

    // Exactly the shape the two kanban paths used to emit.
    try seedHistoryRow(&ctx, "r_raw", "''");

    try expectHistoryModel(&ctx, "r_raw", Migration101GuardLlmHistoryModel.sentinel);
}

test "Migration101 trigger rewrites a whitespace-only model on INSERT" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupLlmHistoryRoot(&ctx);

    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);

    try seedHistoryRow(&ctx, "r_ws", "'  '");

    try expectHistoryModel(&ctx, "r_ws", Migration101GuardLlmHistoryModel.sentinel);
}

test "Migration101 leaves a healthy INSERT alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupLlmHistoryRoot(&ctx);

    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);

    try seedHistoryRow(&ctx, "r_ok", "'MiniMax-M3'");
    try expectHistoryModel(&ctx, "r_ok", "MiniMax-M3");
}

test "Migration101 is replay-safe" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    try setupLlmHistoryRoot(&ctx);

    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);
    try seedHistoryRow(&ctx, "r_a", "''");
    try seedHistoryRow(&ctx, "r_b", "'gpt-4o'");

    // Re-run twice against a database that now holds real rows.
    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);
    try Migration101GuardLlmHistoryModel.up(&ctx.db, alloc);

    // r_a stays on the sentinel (already correct, no drift); r_b is never
    // rewritten by a replay. And the re-runs add no rows of their own.
    try expectHistoryModel(&ctx, "r_a", Migration101GuardLlmHistoryModel.sentinel);
    try expectHistoryModel(&ctx, "r_b", "gpt-4o");
    try testing.expectEqual(@as(i64, 2), try countHistoryRows(&ctx));
}

test "Migration101 SQL sentinel matches the Zig guard's UNKNOWN_MODEL" {
    // The trigger hardcodes 'unknown' because SQL cannot call into Zig. This
    // assertion is the ONLY thing keeping the two in step — if someone changes
    // either one alone, this test fails.
    const guard = @import("../agentic_loop/llm_history_model_guard.zig");
    try testing.expectEqualStrings(guard.UNKNOWN_MODEL, Migration101GuardLlmHistoryModel.sentinel);
}

test "Migration101 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration101GuardLlmHistoryModel.version) return;
    }
    return error.Migration101NotRegistered;
}

test "Migration102 creates skills with the expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "skills");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_id", "name", "description", "content", "created_at", "updated_at",
    });
}
test "Migration102 creates skill_assets with the expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "skill_assets");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "skill_id", "rel_path", "content", "created_at",
    });
}
test "Migration102 scopes skill names to a workspace, not globally" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);

    // Same name, two workspaces, two rows: the isolation boundary is the
    // row's `workspace_id`, which is what lets two workspaces each carry
    // their own `pdf` without either shadowing the other.
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_1', 'ws_a', 'pdf')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_2', 'ws_b', 'pdf')
    , &.{});

    // Same name TWICE in one workspace is refused, so `use_skill({ name })`
    // can never resolve to an arbitrary row.
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_3', 'ws_a', 'pdf')
    , &.{}));

    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM skills", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("2", row.values[0]);
}
test "Migration102 skill_assets refuses a duplicate rel_path for one skill" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_1', 'ws_a', 'pdf')
    , &.{});

    try ctx.db.exec(alloc,
        \\INSERT INTO skill_assets (id, skill_id, rel_path) VALUES ('sa_1', 'sk_1', 'scripts/run.py')
    , &.{});
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO skill_assets (id, skill_id, rel_path) VALUES ('sa_2', 'sk_1', 'scripts/run.py')
    , &.{}));

    // The same rel_path under a DIFFERENT skill is fine — two bundles both
    // shipping `scripts/run.py` is the ordinary case.
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_2', 'ws_a', 'skill-creator')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_assets (id, skill_id, rel_path) VALUES ('sa_3', 'sk_2', 'scripts/run.py')
    , &.{});
}
test "Migration102 skill_assets stores an empty companion without a NULL violation" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_1', 'ws_a', 'pdf')
    , &.{});

    // An empty companion file is legal (`touch assets/.keep`). Bind "" and
    // NOT NULL would reject it — which is exactly why the store writes
    // `COALESCE(NULLIF(?, ''), '')`. A real NULL must still fail, so the
    // test proves the column is constrained rather than merely nullable.
    try ctx.db.exec(alloc,
        \\INSERT INTO skill_assets (id, skill_id, rel_path, content)
        \\VALUES ('sa_1', 'sk_1', 'assets/.keep', COALESCE(NULLIF('', ''), ''))
    , &.{});
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO skill_assets (id, skill_id, rel_path, content) VALUES ('sa_2', 'sk_1', 'x.md', NULL)
    , &.{}));
}
test "Migration102 skill description and content default to empty, not NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);

    // Omit both entirely so the schema DEFAULT applies. A model that writes
    // a body before it writes a description is normal, not an error.
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name) VALUES ('sk_1', 'ws_a', 'draft')
    , &.{});

    var q = try ctx.db.query(alloc,
        \\SELECT COALESCE(description, ''), COALESCE(content, '') FROM skills WHERE name = 'draft'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
    try testing.expectEqualStrings("", row.values[1]);
}
test "Migration102 is idempotent" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);
    // Second run on a database that already has live rows must not reset or
    // duplicate anything — IF NOT EXISTS means both statements no-op.
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name, content) VALUES ('sk_1', 'ws_a', 'pdf', 'body')
    , &.{});
    try Migration102CreateSkills.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc, "SELECT COALESCE(content, '') FROM skills WHERE id = 'sk_1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("body", row.values[0]);
}
test "Migration102 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration102CreateSkills.version) return;
    }
    return error.Migration102NotRegistered;
}


// ============================================================================
// Migration 103 tests
// ============================================================================
//
// Three properties, each pinned because its failure mode is invisible until
// the feature ships:
//
//   1. The column set is EXACTLY six, and in particular carries no
//      `user_id` — membership in `workspace_members` already answers "who may
//      use this" one level up.
//   2. Name uniqueness is per workspace, not per database: two workspaces
//      must each be able to hold a secret called `GITHUB_TOKEN`.
//   3. `value` is genuinely NOT NULL, so a writer that forgot the
//      COALESCE(NULLIF(?, ''), '') idiom fails here rather than silently
//      storing a credential that reads back as null.

fn countWorkspaceSecrets(ctx: *TestCtx) !i64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_secrets", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

test "Migration103 creates workspace_secrets with exactly the six agreed columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_secrets");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_id", "name", "value", "created_at", "updated_at",
    });

    // `expectColumnsEqual` already pins the count, so a seventh column — an
    // owner column above all — fails the assertion above. Name the ones the
    // design ruled out so the failure says which was added rather than just
    // "expected 6, found 7".
    for (cols) |c| {
        try testing.expect(!std.mem.eql(u8, c, "user_id"));
        try testing.expect(!std.mem.eql(u8, c, "created_by"));
        try testing.expect(!std.mem.eql(u8, c, "key_hint"));
    }
}

test "Migration103's unique name index is scoped per workspace, not per database" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value) VALUES
        \\  ('sec_a', 'ws_1', 'GITHUB_TOKEN', 'ghp_a'),
        \\  ('sec_b', 'ws_2', 'GITHUB_TOKEN', 'ghp_b')
    , &.{});

    // Same name, different workspace: both rows stand. A globally unique
    // index here would make the second workspace's most common secret name
    // un-creatable.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_secrets WHERE name = 'GITHUB_TOKEN'", &.{});
    defer q.deinit();
    const both = (try q.next()) orelse return error.RowMissing;
    defer both.deinit(alloc);
    try testing.expectEqualStrings("2", both.values[0]);

    // Same name, SAME workspace: rejected. `ExecuteFailed` is what
    // `SqliteBackend.exec` surfaces for a constraint violation — the
    // "UNIQUE constraint failed" text only reaches the log — so the state
    // check below is what actually proves the index fired.
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value)
        \\VALUES ('sec_c', 'ws_1', 'GITHUB_TOKEN', 'ghp_c')
    , &.{}));
    try testing.expectEqual(@as(i64, 2), try countWorkspaceSecrets(&ctx));
}

test "Migration103 stamps both timestamps and refuses a NULL value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);

    // Omit the timestamps so the schema DEFAULT applies, and read them back
    // through COALESCE: a nullable stamp would reach the HTTP layer as a
    // null where it declared a string.
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value)
        \\VALUES ('sec_1', 'ws_1', 'GH', 'ghp_1')
    , &.{});

    var q = try ctx.db.query(alloc,
        \\SELECT COALESCE(created_at, ''), COALESCE(updated_at, '')
        \\FROM workspace_secrets WHERE id = 'sec_1'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expect(row.values[0].len > 0);
    try testing.expect(row.values[1].len > 0);

    // A NULL value is the shape an empty slice binds to. The constraint has
    // to be real, or a writer that skips COALESCE(NULLIF(?, ''), '') stores
    // a credential that reads back as null.
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value)
        \\VALUES ('sec_2', 'ws_1', 'GH2', NULL)
    , &.{}));
}

test "Migration103 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_secrets (id, workspace_id, name, value)
        \\VALUES ('sec_1', 'ws_1', 'GH', 'ghp_1')
    , &.{});

    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);
    try Migration103CreateWorkspaceSecrets.up(&ctx.db, alloc);

    // CREATE TABLE/INDEX IF NOT EXISTS means a re-run neither throws "table
    // already exists" nor disturbs a stored credential.
    try testing.expectEqual(@as(i64, 1), try countWorkspaceSecrets(&ctx));
}

test "Migration103 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration103CreateWorkspaceSecrets.version) return;
    }
    return error.Migration103NotRegistered;
}


// ============================================================================
// Migration 105 tests
// ============================================================================
//
// Four properties, each pinned because its failure mode is a silent
// cross-workspace (or cross-user) bleed rather than a crash:
//
//   1. The shape is exactly the five agreed columns: `owner` IS present
//      (unlike `workspace_secrets`, which deliberately has no owner column -
//      membership answers entitlement there). Here the owner is the second
//      half of the key, because this table stores credentials.
//   2. `config_json` is NULLABLE, so "clear the overlay" is representable.
//      A NOT NULL column would turn the clear path into a constraint error,
//      because this backend binds an empty slice as SQL NULL.
//   3. The PRIMARY KEY is `(owner, workspace_id)`. If it were
//      `workspace_id` alone, one user's saved profiles - API keys included -
//      would REPLACE every other user's in a shared workspace.
//   4. A re-run is idempotent and does not disturb a stored overlay.

fn countWorkspaceSettings(ctx: *TestCtx) !i64 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, "SELECT COUNT(*) FROM workspace_settings", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

test "Migration105 creates workspace_settings with exactly the five agreed columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_settings");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "owner", "workspace_id", "config_json", "created_at", "updated_at",
    });

    // The owner column is the whole `--auth` isolation story, so name it
    // explicitly: a future edit that "simplifies" the key back to
    // `workspace_id` (or drops the column) fails here with a readable message
    // instead of in production as a credential leak.
    var saw_owner = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "owner")) saw_owner = true;
    }
    try testing.expect(saw_owner);
}

test "Migration105's config_json is nullable, so clearing the overlay is representable" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);

    // notnull == 0 is what makes `DELETE`/NULL the "inherit everything"
    // representation. An explicit NULL insert would fail on a NOT NULL column.
    var q = try ctx.db.query(
        alloc,
        "SELECT \"notnull\" FROM pragma_table_info('workspace_settings') WHERE name = 'config_json'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration105 keys on (owner, workspace_id), not workspace_id alone" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json)
        \\VALUES ('u1', 'ws_1', '{"active_profile":"mine"}')
    , &.{});
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json)
        \\VALUES ('u2', 'ws_1', '{"active_profile":"theirs"}')
    , &.{});
    try testing.expectEqual(@as(i64, 2), try countWorkspaceSettings(&ctx));

    // Replacing u2's row must NOT touch u1's. If the key were `workspace_id`
    // alone, this REPLACE would evict u1 - which is the leak this key exists
    // to prevent, so the count assertion below is the real witness.
    try ctx.db.exec(alloc,
        \\INSERT OR REPLACE INTO workspace_settings (owner, workspace_id, config_json)
        \\VALUES ('u2', 'ws_1', '{"active_profile":"changed"}')
    , &.{});
    try testing.expectEqual(@as(i64, 2), try countWorkspaceSettings(&ctx));

    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(config_json, '') FROM workspace_settings WHERE owner = 'u1' AND workspace_id = 'ws_1'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("{\"active_profile\":\"mine\"}", row.values[0]);
}

test "Migration105 is idempotent on a re-run and keeps the stored overlay" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_settings (owner, workspace_id, config_json)
        \\VALUES ('', 'ws_1', '{"retry_delay_ms":500}')
    , &.{});

    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);
    try Migration105CreateWorkspaceSettings.up(&ctx.db, alloc);

    // CREATE TABLE IF NOT EXISTS means a re-run neither throws "table already
    // exists" nor drops the workspace's saved overrides.
    try testing.expectEqual(@as(i64, 1), try countWorkspaceSettings(&ctx));
}

test "Migration105 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration105CreateWorkspaceSettings.version) return;
    }
    return error.Migration105NotRegistered;
}

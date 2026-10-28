const std = @import("std");
const pabrikcore = @import("pabrikcore");
const test_db = pabrikcore.test_db;
const helpers = @import("helpers");
const dialect = pabrikcore.dialect;
const common = @import("common.zig");

pub const Migration = common.Migration;
pub const MigrationManager = common.MigrationManager;
pub const Backend = common.Backend;
pub const addColumnIfMissing = common.addColumnIfMissing;
pub const dropColumnIfExists = common.dropColumnIfExists;
pub const renameColumnIfExists = common.renameColumnIfExists;

// Per-version migration modules. File name matches the `version: u32` inside
// (migration_78.zig holds version 78, even though its struct keeps the
// historical `Migration076…` prefix).
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
const migration_106 = @import("migration_106.zig");
const migration_107 = @import("migration_107.zig");
const migration_108 = @import("migration_108.zig");
const migration_109 = @import("migration_109.zig");
const migration_110 = @import("migration_110.zig");
const migration_111 = @import("migration_111.zig");
const migration_112 = @import("migration_112.zig");
const migration_113 = @import("migration_113.zig");
const migration_114 = @import("migration_114.zig");
const migration_115 = @import("migration_115.zig");
const migration_116 = @import("migration_116.zig");
const migration_117 = @import("migration_117.zig");
const migration_118 = @import("migration_118.zig");
const migration_119 = @import("migration_119.zig");
const migration_120 = @import("migration_120.zig");
const migration_121 = @import("migration_121.zig");

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
pub const Migration106CreateModelCatalog = migration_106.Migration106CreateModelCatalog;
pub const Migration107AddBackgroundProcessKind = migration_107.Migration107AddBackgroundProcessKind;
pub const Migration108AddBackgroundProcessReadOffset = migration_108.Migration108AddBackgroundProcessReadOffset;
pub const Migration109AddSkillCanAutoImprove = migration_109.Migration109AddSkillCanAutoImprove;
pub const Migration110AddTaskSkillName = migration_110.Migration110AddTaskSkillName;
pub const Migration111AddKanbanTaskDependencies = migration_111.Migration111AddKanbanTaskDependencies;
pub const Migration112RenameTaskSkillNames = migration_112.Migration112RenameTaskSkillNames;
pub const Migration113AddGuestJobColumns = migration_113.Migration113AddGuestJobColumns;
pub const Migration114AddFileAttachments = migration_114.Migration114AddFileAttachments;
pub const Migration115AddWorkspaceIsVm = migration_115.Migration115AddWorkspaceIsVm;
pub const Migration116UnifyAgentConfigTables = migration_116.Migration116UnifyAgentConfigTables;
pub const Migration117DropLegacyAgentConfigTables = migration_117.Migration117DropLegacyAgentConfigTables;
pub const Migration118AddWorkerRunToken = migration_118.Migration118AddWorkerRunToken;
pub const Migration119CreateSkillMetadata = migration_119.Migration119CreateSkillMetadata;
pub const Migration120GrantSetSkillMetadata = migration_120.Migration120GrantSetSkillMetadata;
pub const Migration121AddSqliteTimeFunctions = migration_121.Migration121AddSqliteTimeFunctions;

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
    // `last_human_touched_at` on tasks the user has interacted with (drag,
    // rename, edit desc, pin, send message, open chat).
    .{ .version = Migration065AddTaskHumanTouchedAt.version, .name = Migration065AddTaskHumanTouchedAt.name, .up = Migration065AddTaskHumanTouchedAt.up },
    // design-page-workspace-item-task-fk plan, Task 1: adds the FK column +
    // UNIQUE index + backfill so each design page is bound to its chat task
    // at the row level (replaces the name-pattern lookup in
    .{ .version = Migration066AddDesignPageTaskFk.version, .name = Migration066AddDesignPageTaskFk.name, .up = Migration066AddDesignPageTaskFk.up },
    // kanban task tags plan, Task 1: adds `tags TEXT NOT NULL DEFAULT ''`
    // so workspace_item_tasks rows can carry a JSON-encode array of user
    // labels.
    .{ .version = Migration067AddTaskTags.version, .name = Migration067AddTaskTags.name, .up = Migration067AddTaskTags.up },
    // tool-call-loading-placeholder plan, Task 1: adds
    // `llm_history.is_loading` + partial UNIQUE INDEX on `tool_call_id` so we
    // can pre-create tool-result placeholder rows synchronously BEFORE the
    .{ .version = Migration068AddToolCallLoading.version, .name = Migration068AddToolCallLoading.name, .up = Migration068AddToolCallLoading.up },
    // Migration 069 — adds `workspace_item_tasks.image_urls` so task images
    // are stored inline (base64 data URLs joined with `||`) on the task row,
    // no filesystem attachments, no broken GET route.
    .{ .version = Migration069AddTaskImageUrls.version, .name = Migration069AddTaskImageUrls.name, .up = Migration069AddTaskImageUrls.up },
    // Migration 070 — agent_memories table + agent_memories_fts FTS5 +
    // 3 sync triggers. Backs the save_memory + load_memory agent tools
    // (Task task_1785958319567, plan 2026-08-06-save-load-memory-fts5).
    .{ .version = Migration070AddAgentMemories.version, .name = Migration070AddAgentMemories.name, .up = Migration070AddAgentMemories.up },
    // Migration 071 — adds `workspace_item_tasks.cwd` (the per-task
    // cwd_session).
    .{ .version = Migration071AddTaskCwd.version, .name = Migration071AddTaskCwd.name, .up = Migration071AddTaskCwd.up },
    // Migration 072 — extracts `kanban_column_id` + `kanban_position` off
    // `workspace_item_tasks` into a dedicated `kanban` join table; wire
    // format preserved (Task.{kanban_column_id, kanban_position} continue to
    .{ .version = Migration072ExtractKanbanTable.version, .name = Migration072ExtractKanbanTable.name, .up = Migration072ExtractKanbanTable.up },
    // Migration 073 — session_activity append-only log (update_activity +
    // buildCompactionEnvelope now INSERT here in addition to the existing
    // worker.last_activity_description UPDATE).
    .{ .version = Migration073AddSessionActivity.version, .name = Migration073AddSessionActivity.name, .up = Migration073AddSessionActivity.up },
    .{ .version = Migration074AddLlmHistoryCacheTokenColumns.version, .name = Migration074AddLlmHistoryCacheTokenColumns.name, .up = Migration074AddLlmHistoryCacheTokenColumns.up },
    // Migration 075 — renames 5 timestamp columns to use the `_nano` suffix
    // (`logs.created_at` → `logs.created_at_nano`, etc.). Wire format
    // preserved.
    .{ .version = Migration075RenameTimestampColumnsToNanoSuffix.version, .name = Migration075RenameTimestampColumnsToNanoSuffix.name, .up = Migration075RenameTimestampColumnsToNanoSuffix.up },
    // Migration 076 — `session_plan` 1:1 table with `sessions` for the
    // agent's persistent task plan (markdown + checklist).
    .{ .version = Migration076CreateSessionPlan.version, .name = Migration076CreateSessionPlan.name, .up = Migration076CreateSessionPlan.up },
    // Migration 077 — `users` + `user_companies` + `user_company_members` +
    // additive `workspaces.user_id` + `sessions.user_id` + default
    // `user_system` user + backfill.
    .{ .version = Migration077AddUsersAndRbacSchema.version, .name = Migration077AddUsersAndRbacSchema.name, .up = Migration077AddUsersAndRbacSchema.up },
    // Migration 078 — Agent Mode: `agents` + `agent_knowledge` +
    // `agent_tools` (4th workspace-item type, knowledge injection, tool
    // allowlist).
    .{ .version = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.version, .name = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.name, .up = Migration076AddAgentsAndAgentKnowledgeAndAgentTools.up },
    // Migration 079 — agent_knowledge.content (manual text knowledge).
    // Task: task_1787315943769_9.
    .{ .version = Migration079AddContentToAgentKnowledge.version, .name = Migration079AddContentToAgentKnowledge.name, .up = Migration079AddContentToAgentKnowledge.up },
    // Migration 080 — agent_system_prompt (N-1 with agents, per-agent named
    // prompt blocks injected into the LLM system message).
    .{ .version = Migration080AddAgentSystemPrompt.version, .name = Migration080AddAgentSystemPrompt.name, .up = Migration080AddAgentSystemPrompt.up },
    // Migration 081 — Agent-Kanbans mirror: agent_kanbans (1-1 with kanban
    // workspace_items) + knowledges + system_prompt + tools children.
    .{ .version = Migration081CreateAgentKanbans.version, .name = Migration081CreateAgentKanbans.name, .up = Migration081CreateAgentKanbans.up },
    // Migration 082 — sessions.last_human_touched_at_nano column. Sibling of
    // Migration 065's task-side column.
    .{ .version = Migration082AddSessionHumanTouchedAt.version, .name = Migration082AddSessionHumanTouchedAt.name, .up = Migration082AddSessionHumanTouchedAt.up },
    // Migration 083 — llm_history reasoning metadata (reasoning_id +
    // reasoning_encrypted_content).
    .{ .version = Migration083AddReasoningIdAndEncryptedContent.version, .name = Migration083AddReasoningIdAndEncryptedContent.name, .up = Migration083AddReasoningIdAndEncryptedContent.up },
    // Migration 084 — drop per-task `routines`, replace with workspace-level
    // `workspace_routines` (first-class `item_type='routine'` beside
    // `agent`).
    .{ .version = Migration084ReplaceRoutinesWithWorkspaceRoutines.version, .name = Migration084ReplaceRoutinesWithWorkspaceRoutines.name, .up = Migration084ReplaceRoutinesWithWorkspaceRoutines.up },
    .{ .version = Migration085AddSessionProgressiveTool.version, .name = Migration085AddSessionProgressiveTool.name, .up = Migration085AddSessionProgressiveTool.up },
    .{ .version = Migration086AddSessionPrUrl.version, .name = Migration086AddSessionPrUrl.name, .up = Migration086AddSessionPrUrl.up },
    .{ .version = Migration087CreateAgentRoutines.version, .name = Migration087CreateAgentRoutines.name, .up = Migration087CreateAgentRoutines.up },
    // Migration 088 — the `ask_user` question queue: one row per pending
    // question, answered later by POST /api/llm/session/:id/answer which
    // rewrites the matching tool-result row and resumes the session.
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
    // Migration 093 — owner columns for per-user row isolation. Adds
    // worker.user_id (+ index) and backfills every still-NULL
    // workspaces/sessions/worker row to the shared `user_system` sentinel.
    .{ .version = Migration093AddOwnerColumns.version, .name = Migration093AddOwnerColumns.name, .up = Migration093AddOwnerColumns.up },
    // Migration 094 — `workspace_items.is_default`, the per-workspace default
    // project.
    .{ .version = Migration094AddDefaultProjectToWorkspaceItems.version, .name = Migration094AddDefaultProjectToWorkspaceItems.name, .up = Migration094AddDefaultProjectToWorkspaceItems.up },
    // Migration 095 — `agent_memories.workspace_id`, so `save_memory` /
    // `load_memory` stop sharing one note pool across every workspace.
    .{ .version = Migration095AddWorkspaceIdToAgentMemories.version, .name = Migration095AddWorkspaceIdToAgentMemories.name, .up = Migration095AddWorkspaceIdToAgentMemories.up },
    // Migration 096 — `session_skill_events`, the append-only skill usage
    // ledger.
    .{ .version = Migration096CreateSessionSkillEvents.version, .name = Migration096CreateSessionSkillEvents.name, .up = Migration096CreateSessionSkillEvents.up },
    // Migration 097 — the skill-eval tables.
    .{ .version = Migration097CreateSkillEvalTables.version, .name = Migration097CreateSkillEvalTables.name, .up = Migration097CreateSkillEvalTables.up },
    // Migration 098 — the `documents` table: workspace-scoped markdown
    // documents surfaced in their own sidebar section below Projects.
    .{ .version = Migration098CreateDocuments.version, .name = Migration098CreateDocuments.name, .up = Migration098CreateDocuments.up },
    // Migration 099 — rename the `list_skills` agent tool to `search_skills`.
    .{ .version = Migration099RenameListSkillsTool.version, .name = Migration099RenameListSkillsTool.name, .up = Migration099RenameListSkillsTool.up },
    // Migration 100 — `workspace_members`: moves workspace ownership off the
    // single `workspaces.user_id` column onto a many-to-many join table so
    // one workspace can be shared.
    .{ .version = Migration100AddWorkspaceMembers.version, .name = Migration100AddWorkspaceMembers.name, .up = Migration100AddWorkspaceMembers.up },
    // Migration 101 — `llm_history.model` is never empty.
    .{ .version = Migration101GuardLlmHistoryModel.version, .name = Migration101GuardLlmHistoryModel.name, .up = Migration101GuardLlmHistoryModel.up },
    // Migration 102 — the `skills` table: workspace-scoped skill bodies.
    .{ .version = Migration102CreateSkills.version, .name = Migration102CreateSkills.name, .up = Migration102CreateSkills.up },
    .{ .version = Migration103CreateWorkspaceSecrets.version, .name = Migration103CreateWorkspaceSecrets.name, .up = Migration103CreateWorkspaceSecrets.up },
    .{ .version = Migration104AddSessionPinned.version, .name = Migration104AddSessionPinned.name, .up = Migration104AddSessionPinned.up },
    // Migration 105 - the per-workspace config OVERLAY.
    .{ .version = Migration105CreateWorkspaceSettings.version, .name = Migration105CreateWorkspaceSettings.name, .up = Migration105CreateWorkspaceSettings.up },
    .{ .version = Migration106CreateModelCatalog.version, .name = Migration106CreateModelCatalog.name, .up = Migration106CreateModelCatalog.up },
    // `kind` ('job' | 'service') is what makes
    // `mode="background_persistence"` silent in BOTH places that can notify —
    // the immediate watcher is not scheduled for a service, and the
    .{ .version = Migration107AddBackgroundProcessKind.version, .name = Migration107AddBackgroundProcessKind.name, .up = Migration107AddBackgroundProcessKind.up },
    // The read cursor for the `process read` tool: how much of a detached
    // process's log the agent has already been shown, so a poll returns only
    // what is new. See migration_108.zig.
    .{ .version = Migration108AddBackgroundProcessReadOffset.version, .name = Migration108AddBackgroundProcessReadOffset.name, .up = Migration108AddBackgroundProcessReadOffset.up },
    .{ .version = Migration109AddSkillCanAutoImprove.version, .name = Migration109AddSkillCanAutoImprove.name, .up = Migration109AddSkillCanAutoImprove.up },
    // Migration 110 — the skill a kanban task asks the agent to use.
    .{ .version = Migration110AddTaskSkillName.version, .name = Migration110AddTaskSkillName.name, .up = Migration110AddTaskSkillName.up },
    // Migration 111 — kanban task dependencies: the `kanban_task_dependencies`
    // edge table plus `kanban_columns.is_done`, with a name-based backfill.
    .{ .version = Migration111AddKanbanTaskDependencies.version, .name = Migration111AddKanbanTaskDependencies.name, .up = Migration111AddKanbanTaskDependencies.up },
    // Migration 112 — one task may ask for several skills: `skill_name`
    // becomes `skill_names` (`||`-joined). A rename, so existing rows and
    // the column's position both survive.
    .{ .version = Migration112RenameTaskSkillNames.version, .name = Migration112RenameTaskSkillNames.name, .up = Migration112RenameTaskSkillNames.up },
    .{ .version = Migration113AddGuestJobColumns.version, .name = Migration113AddGuestJobColumns.name, .up = Migration113AddGuestJobColumns.up },
    // Migration 114 — the chat's file attachments: the payload for the model
    // and the metadata for the read path.
    .{ .version = Migration114AddFileAttachments.version, .name = Migration114AddFileAttachments.name, .up = Migration114AddFileAttachments.up },
    // Migration 115 — a workspace records whether it is a microVM workspace.
    .{ .version = Migration115AddWorkspaceIsVm.version, .name = Migration115AddWorkspaceIsVm.name, .up = Migration115AddWorkspaceIsVm.up },
    // Migration 116 — the three per-item-type agent-config table families
    // (12 tables) collapse into ONE set of four. `item_type` on the parent
    // row tells the families apart. See migration_116.zig.
    .{ .version = Migration116UnifyAgentConfigTables.version, .name = Migration116UnifyAgentConfigTables.name, .up = Migration116UnifyAgentConfigTables.up },
    // Migration 117 — the legacy tables the unification parked are no
    // longer needed: drop them.
    .{ .version = Migration117DropLegacyAgentConfigTables.version, .name = Migration117DropLegacyAgentConfigTables.name, .up = Migration117DropLegacyAgentConfigTables.up },
    // Migration 118 — `worker.run_token`: the per-session run lease the
    // workflow claims in a transaction, so one session runs one loop.
    .{ .version = Migration118AddWorkerRunToken.version, .name = Migration118AddWorkerRunToken.name, .up = Migration118AddWorkerRunToken.up },
    // Migration 119 — `skill_metadata`: the SKILL.md frontmatter keys with
    // no dedicated column become rows, derived from `skills.content`.
    .{ .version = Migration119CreateSkillMetadata.version, .name = Migration119CreateSkillMetadata.name, .up = Migration119CreateSkillMetadata.up },
    // Migration 120 — grant `set_skill_metadata` to every config that already
    // has `edit_skill`. A new tool NAME does not reach an existing agent: its
    // allowlist rows are already seeded, so only a migration can add one.
    .{ .version = Migration120GrantSetSkillMetadata.version, .name = Migration120GrantSetSkillMetadata.name, .up = Migration120GrantSetSkillMetadata.up },
    // Migration 121 — `datetime(...)` / `strftime(...)` as postgres functions, so the ~260 statements
    // that already spell them stay identical on both engines (a no-op on sqlite).
    .{ .version = Migration121AddSqliteTimeFunctions.version, .name = Migration121AddSqliteTimeFunctions.name, .up = Migration121AddSqliteTimeFunctions.up },
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

// ────────────────────────────────────────────────────────────────────────
// Migration 055 — design_pages table (v1 of design-mode feature)
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// Migration 056 — upgrade design_pages to file-backed model
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// Migration 057 — add v6 element properties to design_page_elements
// ────────────────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────────────────
// Migration 058 — FTS5 virtual table on llm_history (workspace history
// search)




















// ============================================================================
// Migration 073 — `session_activity` append-only log.
// ============================================================================



// ============================================================================
// Migration 076 — Agent Mode: `agents` + `agent_knowledge` + `agent_tools`
// ============================================================================

// ============================================================================
// Migration 070 — `agent_memories` + `agent_memories_fts` for save_memory /
// load_memory tools

// ─── Tests for Migration 078 (Agent Mode) ──────────────────────────────
// impl + tests in one file (project convention).
// `std` is already in scope from line 1; only the local aliases need adding.
const testing = std.testing;
const sqlite = @import("pabrikcore").sqlite;
const Migration078 = Migration076AddAgentsAndAgentKnowledgeAndAgentTools;


/// Top-level named struct (NOT inline anonymous) per project memory
/// `zig-anonymous-struct-type-identity.md` — Zig 0.16 treats two anonymous
/// `struct { db, threaded }` types as distinct types even with identical
const TestCtx = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    return .{ .db = db, .threaded = threaded };
}

/// Helper: run the migration, then return the list of column names for a
/// given table (ordered by `cid`, the original CREATE order).
fn columnsOf(ctx: *TestCtx, table: []const u8) ![]const []const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc, if (dialect.is_postgres)
        "SELECT column_name FROM information_schema.columns " ++
            "WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position"
    else
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
    // Caller MUST `free` the slice header AND each element.
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

// Migration 099 — rename the `list_skills` agent tool to `search_skills`. WHY
// a data migration: the tool name is not decoration, it is a PERSISTED
// allowlist entry.

// ───────────────────────── tests: Migration 099 ─────────────────────────

test "Migration099 renames agent_tools rows and preserves enabled + count" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
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
            "CREATE TABLE {s} (id TEXT PRIMARY KEY, {s} TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE({s}, tool_name))",
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

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
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

    try ctx.db.exec(alloc, "CREATE TABLE agent_tools (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, tool_name TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE(agent_id, tool_name))", &[_][]const u8{});
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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agents'",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agents'",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' AND tbl_name='agents'",
        &.{});
    defer q.deinit();
    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        // The UNIQUE constraint produces an auto-index; the existence of ANY
        // index on agents in addition to idx_agents_workspace_item_id is our
        // proxy.
        found = true;
    }
    try testing.expect(found); // at least one index exists

    // Tighter check: INSERT two rows with the same workspace_item_id. The
    // second must fail with a UNIQUE violation. We need a parent
    // workspace_items row first (FK).
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' AND name='uq_agent_tools_agent_tool'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UniqueIndexNotCreated;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("uq_agent_tools_agent_tool", row.values[0]);

    // Tighter check: insert parent rows, then duplicate tool_name → expect UNIQUE violation.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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
    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});
    try Migration078.up(&ctx.db, alloc);

    // Create the parent workspace_items row + agent + 1 knowledge + 1 tool.
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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

    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});
    try Migration078.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' AND name='idx_agent_knowledge_agent_id_position'",
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
            "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name=?",
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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("agent_knowledge") ++ " WHERE name = 'content'",
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

// ============================================================================
// Migration 076 — `session_plan` 1:1 table with `sessions` for the agent's
// persistent task plan (markdown + checklist).

// ============================================================================
// Migration 077 — users + user_companies + user_company_members +
// workspaces.user_id + sessions.user_id + default user_system + backfill.

// ============================================================================
// Migration 080 — `agent_system_prompt` (N-1 with agents)
// ============================================================================

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

    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});
    // Production order: parent tables first (agents), then the new table.
    try Migration078.up(&ctx.db, alloc);
    try Migration080AddAgentSystemPrompt.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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





// ============================================================================
// Migration 085 — session_progressive_tool (progressive tool search)
// ============================================================================




// ============================================================================
// Migration 089 — auth_sessions for opt-in `--auth` login sessions.
// ============================================================================


// Migration 091 — sessions.sub_agent_name + sessions.parent_session_id.

// Migration 092 — users.config_json for opt-in `--auth` mode.

// Migration 093 — owner columns for per-user row isolation.
// `workspaces.user_id` and `sessions.user_id` have existed since Migration
// 077 but nothing has ever written them; `worker` has no owner column at all.

// ============================================================================
// Migration 094 — mark one workspace item as the workspace's default project.
// ============================================================================

// Migration 096 — `session_skill_events`, the skill usage ledger.
// ============================================================================
// `session_skills` (Migration 008) keeps only the LATEST body of each skill a

// ============================================================================
// Migration 097 — the skill-eval tables: shared facts, runs, results.
// ============================================================================

// ============================================================================
// Migration 095 — per-workspace isolation for `agent_memories`.
// ============================================================================

// ============================================================================
// Migration 087 — agent config tables for routine workspace items.
// ============================================================================

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
            "SELECT 1 FROM " ++ comptime dialect.tableColumns("llm_history") ++ " WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
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
        "SELECT name, type, \"notnull\" FROM " ++ comptime dialect.tableColumns("llm_history") ++ " WHERE name IN ('reasoning_id', 'reasoning_encrypted_content') ORDER BY name",
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

    // NULL handling: legacy row without reasoning metadata should read as "" (Backend NULL → "").
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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("llm_history") ++ " WHERE name IN ('reasoning_id', 'reasoning_encrypted_content')",
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

    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});
    // Production order: parent tables first (agents), then the new tables.
    try Migration078.up(&ctx.db, alloc);
    try Migration081.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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
        \\    last_run_at TIMESTAMP,
        \\    next_run_at TIMESTAMP NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't_rout', '* * * * *', 'hi', '2026-01-01 00:00:00')",
        &.{});

    try Migration084.up(&ctx.db, alloc);

    // Old table is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = 'routines'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }
    // Old indexes are gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name LIKE 'idx_routines_%'",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = 'workspace_routines'",
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

    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});
    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, task_type TEXT NOT NULL DEFAULT 'standard')",
        &.{});
    try Migration084.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT, name TEXT, path TEXT, position INTEGER, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = 'workspace_routines'",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = 'session_progressive_tool'",
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
        "SELECT name, type, \"notnull\" FROM " ++ comptime dialect.tableColumns("sessions") ++ " WHERE name IN ('pr_url', 'pr_provider') ORDER BY name",
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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("sessions") ++ " WHERE name IN ('pr_url', 'pr_provider')",
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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = ?",
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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("sessions") ++ " WHERE name IN ('sub_agent_name', 'parent_session_id')",
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

    // Nullable TEXT: an empty-string bind (which Backend collapses to
    // SQL NULL) must never violate the column.
    var q = try ctx.db.query(alloc,
        "SELECT type, \"notnull\" FROM " ++ comptime dialect.tableColumns("worker") ++ " WHERE name = 'user_id'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", row.values[0]);
    try testing.expectEqualStrings("0", row.values[1]);

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_worker_user_id'",
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

    // The whole point of NOT NULL DEFAULT 0: pre-existing rows must read back
    // as ordinary projects, with no backfill UPDATE and no table rewrite.
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
        "SELECT type, \"notnull\", dflt_value FROM " ++ comptime dialect.tableColumns("workspace_items") ++ " WHERE name = 'is_default'",
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
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_agent_memories_workspace'",
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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB and apply migrations 001–008, matching
/// the schema state that migration 009 was always meant to consume.

fn setupDb009() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
// This is the canonical regression test for the "fresh-DB crash" bug.

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
            "SELECT name FROM " ++ comptime dialect.tableColumns("llm_history") ++ " WHERE name IN ('created', 'created_at')",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE name IN ('llm_history', 'llm_history_old') ORDER BY name",
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
// Verifies that the COALESCE(created_at, CURRENT_TIMESTAMP) fix doesn't
// silently NULL out pre-existing rows.

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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the workspace_item_tasks table
/// present (matching the state after Migration 034), ready for
/// Migration 044 to add the `task_type` column on top.

fn setupDb044() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Mirror the state left by Migration 034 exactly — same columns,
    // same NULL/NOT NULL semantics, same default timestamps. This is
    // what a real DB looks like the moment before Migration 044 runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    session_id TEXT,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText044(alloc: std.mem.Allocator, db: *Backend, sql: []const u8, args: []const []const u8) ![]u8 {
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

    // Read each column separately. SQLite `||` with a NULL operand returns
    // NULL, so we can't use string concatenation as a one-shot "all columns
    // in one string" check.
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' AND name='idx_routines_enabled_next_run'",
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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the `llm_history` table present
/// (matching the schema created by Migration 001), ready for
/// Migration 048 to add the `idx_llm_history_created_session` index on top.

fn setupDb048() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Mirror the state left by Migration 001 exactly — same columns, same
    // NULL/NOT NULL semantics.
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
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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

    // Query sqlite_master for the index name. If the migration forgot to
    // create the index, the query returns zero rows.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT COUNT(*) FROM 
        ++ dialect.tables_source ++
        \\
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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with BOTH `workspace_items` and
/// `routines` (plus the FK parent `workspace_item_tasks`) present — matching
/// the schema state just before Migration 049 runs.

fn setupDb049() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // workspace_item_tasks — parent of the routines.task_id FK.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    // workspace_items — minimum columns for the position_id index. The index
    // covers (position DESC, id ASC), so both columns must exist with
    // compatible types.
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    item_type TEXT NOT NULL,
        \\    name TEXT,
        \\    path TEXT,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // routines — minimum columns for the last_status index.
    try db.exec(alloc,
        \\CREATE TABLE routines (
        \\    id TEXT PRIMARY KEY,
        \\    task_id TEXT NOT NULL UNIQUE,
        \\    schedule TEXT NOT NULL,
        \\    initial_prompt TEXT NOT NULL,
        \\    enabled INTEGER NOT NULL DEFAULT 1,
        \\    last_run_at TIMESTAMP,
        \\    next_run_at TIMESTAMP NOT NULL,
        \\    last_status TEXT,
        \\    last_error TEXT,
        \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText049(alloc: std.mem.Allocator, db: *Backend, sql: []const u8, args: []const []const u8) ![]u8 {
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

    // Query sqlite_master for the index name. If the migration forgot to
    // create the index, the query returns zero rows.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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

    // The migration uses `CREATE INDEX IF NOT EXISTS` so a second run is a
    // no-op for both indexes. We assert no error is returned. (Defensive: if
    // a future change drops the IF NOT EXISTS, this test fails immediately.)
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);
    try Migration049AddDefensiveIndexes.up(&ctx.db, alloc);

    // And both indexes are still there exactly once. COUNT(*) is
    // returned as text per the Backend's row-as-text API.
    const wi_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM 
        ++ dialect.tables_source ++
        \\
        \\WHERE type = 'index'
        \\  AND name = 'idx_workspace_items_position_id'
    , &.{});
    defer alloc.free(wi_count);
    try testing.expectEqualStrings("1", wi_count);

    const r_count = try scalarText049(alloc, &ctx.db,
        \\SELECT COUNT(*) FROM 
        ++ dialect.tables_source ++
        \\
        \\WHERE type = 'index'
        \\  AND name = 'idx_routines_last_status'
    , &.{});
    defer alloc.free(r_count);
    try testing.expectEqualStrings("1", r_count);
}

// ===== Tests merged from migration_git_worktree_test.zig (2026-09-29 flatten) =====

// Behavioral tests for Migration 046 (add git_worktree_cwd column to
// sessions).

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the sessions table present
/// (matching the state left by migrations 017 + 022 + 025 + 029 + 040),
/// ready for Migration 046 to add the `git_worktree_cwd` column on top.

fn setupDb046() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Mirror the state left by Migration 017 + 022 + 025 + 029 + 040 exactly
    // — same columns, same NULL/NOT NULL semantics, same default timestamps.
    // This is what a real DB looks like the moment before Migration 046 runs.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    workspace_id TEXT,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText046(alloc: std.mem.Allocator, db: *Backend, sql: []const u8, args: []const []const u8) ![]u8 {
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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` and
/// `workspace_item_tasks` tables present (matching the schema after
/// Migrations 028 and 034), ready for Migration 051 to add the kanban schema

fn setupDb051() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
        "SELECT name FROM " ++ comptime dialect.tableColumns("kanban_columns") ++ " ORDER BY cid",
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
        "SELECT name FROM " ++ comptime dialect.tableColumns("workspace_item_tasks") ++ " " ++
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

fn setupDb053() !struct { db: Backend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target).
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("kanban_columns") ++
        \\ ORDER BY cid
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("kanban_columns") ++
        \\ ORDER BY cid
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

// Static regression checks for Migration 054 (make
// `session_queue_messages.message` nullable).

/// Test fixture for the migration_054 test suite.

const TestCtx054 = struct {
    db: Backend,
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
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
    // RED-GREEN half: this test demonstrates the original bug.
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
        "SELECT \"notnull\" FROM " ++ comptime dialect.tableColumns("session_queue_messages") ++ " " ++
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' " ++
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' " ++
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
        "SELECT name FROM " ++ comptime dialect.tableColumns("session_queue_messages") ++ " ORDER BY cid",
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

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with `workspace_items` + `design_pages`
/// (Migration 055 v1 schema with `html` column) + `design_page_elements`
/// (Migration 056 v5 schema, 12 columns).

fn setupDb057() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
        \\    created_at TIMESTAMP, updated_at TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE)
    , &.{});
    // design_page_elements v5 schema (Migration 056 — 12 columns, no v6 props)
    try db.exec(alloc,
        \\CREATE TABLE design_page_elements (
        \\    id TEXT PRIMARY KEY, page_id TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        \\    file_path TEXT NOT NULL DEFAULT '', x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0, width INTEGER NOT NULL DEFAULT 375,
        \\    height INTEGER NOT NULL DEFAULT 667, z_index INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0, created_at TIMESTAMP, updated_at TIMESTAMP,
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("design_page_elements") ++
        \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("design_page_elements") ++
        \\
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

// Static regression checks for Migration 058 (FTS5 virtual table on
// `llm_history` for workspace history search).

/// Test fixture for the migration_058 test suite.

const TestCtx058 = struct {
    db: Backend,
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Count rows in `sqlite_master` of a given type, optionally matching
/// `tbl_name`. Returns 0 if no match. Helper for the trigger + table tests.
fn countSqliteMaster058(db: *Backend, alloc: std.mem.Allocator, sql: []const u8) !usize {
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='messages_fts'",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='messages_fts'",
        &[_][]const u8{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.VirtualTableNotCreated058;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("messages_fts", row.values[0]);
}

test "migration 058: installs sync triggers (exactly 3 on llm_history)" {
    // The FTS5 triggers exist only on sqlite (postgres indexes `to_tsvector`).
    if (dialect.is_postgres) return error.SkipZigTest;
    // The FTS5 triggers only exist on sqlite: postgres indexes `to_tsvector`
    // instead of maintaining a shadow table, so there is nothing to count.
    if (dialect.is_postgres) return error.SkipZigTest;
    // The migration creates 3 triggers named llm_history_ai, _ad, _au.
    // After Migration 058, querying sqlite_master with
    // `tbl_name='llm_history'` AND `type='trigger'` must return exactly 3.
    const alloc = testing.allocator;
    var ctx = try setupDbWithLlmHistory058();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: pre-migration, zero triggers on llm_history.
    const pre_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 0), pre_count);

    try Migration058AddLlmHistoryFts.up(&ctx.db, alloc);

    // Post-migration: exactly 3 triggers.
    const post_count = try countSqliteMaster058(&ctx.db, alloc,
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='trigger' AND tbl_name='llm_history'");
    try testing.expectEqual(@as(usize, 3), post_count);

    // Verify the exact names (the migration uses _ai, _ad, _au).
    var names_buf: [3][]u8 = .{ &[_]u8{}, &[_]u8{}, &[_]u8{} };
    defer for (names_buf) |n| if (n.len > 0) alloc.free(n);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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

// Static regression checks for Migration 059 (llm_history.created_iso column
// populated by application code + backfill).

const TestCtx059 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB with just the `llm_history` baseline table.
/// Mirrors the migration_058_test.zig / migration_054_test.zig pattern.
fn setupDbWithLlmHistory059() !TestCtx059 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try Migration001CreateLLMHistory.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Read a column attribute by name from `pragma_table_xinfo('llm_history')`.
/// Returns null if the column doesn't exist.
fn columnExists059(
    db: *Backend,
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
    // `created_iso` on new INSERTs.
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

    // Pre-migration: `created_iso` is NULL (no column yet actually, we need
    // to add it first manually to simulate the legacy state). Easier: run the
    // migration itself, which adds the column AND backfills.
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

    // Lex comparison against `created_iso`: rows with created_iso >= new_iso
    // should match.
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
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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

// Static regression checks for Migration 060 (llm_history.created_iso
// re-backfill).

const TestCtx060 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb060() !TestCtx060 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try Migration001CreateLLMHistory.up(&db, alloc);
    // Migration 060 expects `created_iso` to exist. Migration 059
    // creates it (with a backfill that touches the existing rows).
    // Migration 060 then re-runs the backfill.
    try Migration059AddCreatedIso.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 060: re-backfills rows with NULL created_iso" {
    // Simulates the production state: v1 of Migration 059 (broken trigger)
    // left a row with NULL created_iso. v2 of Migration 059 used a different
    // SQL expression that doesn't match what v1's broken trigger would have
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
    // created_iso (because the application ran the corrected saveMessage for
    // new inserts) must NOT be overwritten with a coarser computation.
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

// Static regression checks for Migration 061 (`llm_history.created_iso`
// year-fix).

const TestCtx061 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb061() !TestCtx061 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
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
    // A row whose `created_iso` value matches what the migration would
    // compute from `created_at` MUST be preserved (the LIKE guard stops the
    // UPDATE).
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

const Migration062 = Migration062AddTaskDescription;
const createWorkspaceItemTask = @import("pabrikcore").ai_mod.llm_history.createWorkspaceItemTask;

const TestCtx062 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb062() !TestCtx062 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before migration 061 can run
    // — production walks migrations 001 → 061 in order, so by the time 061
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    // The behavioural tests below INSERT into `task_type` (via the
    // routine/memory branches of task_create.zig and via
    // createWorkspaceItemTask), so the column must exist before Migration 062
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("workspace_item_tasks") ++
            \\
            \\WHERE name = 'description'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply migration 061.
    try Migration062.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Simulate a fresh-DB install where the canonical CREATE TABLE already
    // includes `description TEXT NOT NULL DEFAULT ''`. The migration must be
    // a no-op (NOT a "duplicate column" crash).
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

/// Read back the description column for a task by id.
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
        null,
        // cwd (Migration 070) — null (omitted body field → empty-string
        // sentinel). migration_062_test predates Migration 070 and exercises
        // the description path only; cwd is fully covered in
        null,
        // video_urls (Migration 090) — null. Covered in video_urls_validation tests.
        null,
        // skill_name (Migration 110) — null. Covered in migration_110_test.
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

    // This is the EXACT bug case.
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
        null,
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
        null,
        null);
    defer task.deinit(alloc);

    try testing.expectEqualStrings("hello world from test", task.description);
    try expectDescriptionEquals062(&ctx, alloc, "t_desc_filled_061", "hello world from test");
}

// Direct `db.exec` mirror of the createRoutineTask + createMemoryTask INSERT
// branches.

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

const TestCtx063 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb063() !TestCtx063 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("sessions") ++
            \\
            \\WHERE name = 'is_auto_retry_until_stop'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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
            \\SELECT COUNT(*) FROM 
            ++ comptime dialect.tableColumns("sessions") ++
            \\
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

    // The existing row should now have is_auto_retry_until_stop = '0' (the
    // NOT NULL DEFAULT 0 fires).
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
    // surfaced as "" by Backend per the project's convention;
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

// Behavioral regression tests for the runtime CRUD helpers added with
// Migration 063 (sessions.is_auto_retry_until_stop +
// sessions.last_finish_reason).

const llm_history = pabrikcore.llm_history;

const TestCtx063rt = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb063rt() !TestCtx063rt {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Canonical post-Migration-063 schema.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at TIMESTAMP,
        \\    updated_at TIMESTAMP,
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

/// Reads a single text column from sessions by id. Returns an owned copy
/// (allocated with `testing.allocator`) so the caller can keep the value
/// alive after `row.deinit()`.
fn readColumn063rt(
    ctx: *TestCtx063rt,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    // Backend.query takes argv as []const []const u8 (a slice of string
    // slices), not a tuple.
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

    // Write the new columns directly so we can verify getSession surfaces
    // them — bypass create_session (which coerces the flag). db.exec takes
    // argv as `[]const []const u8` (a slice of strings); an empty `&.{}`
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

// Behavioural tests for Migration 064 (add the `logs` table for frontend
// error capture).

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB. Mirrors the `setupDb` helper in
/// `ai_workflow/tui/routines/Scheduler.zig` (the project's canonical
/// Io.Threaded + :memory: pattern).

fn setupDb064() !struct {
    db: Backend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
        "SELECT name FROM " ++ comptime dialect.tableColumns("logs") ++ " ORDER BY cid",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='index' AND tbl_name='logs' ORDER BY name",
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
    // Second run must not error — `CREATE TABLE IF NOT EXISTS` + `CREATE
    // INDEX IF NOT EXISTS` make this a safe no-op.
    try Migration064AddFrontendLogs.up(&s.db, alloc);
}

// ===== Tests merged from migration_065_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 065
// (`workspace_item_tasks.last_human_touched_at`).

const TestCtx065 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb065() !TestCtx065 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration can
    // run.
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("workspace_item_tasks") ++
            \\
            \\WHERE name = 'last_human_touched_at'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
        \\WHERE name = 'last_human_touched_at'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing065;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the "column
    // literally named INTEGER" footgun from passing only a type to
    // addColumnIfMissing; see project memory
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT or a literal "INTEGER" string in
    // the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Simulate a fresh-DB install where the canonical CREATE TABLE already
    // includes `last_human_touched_at INTEGER`. The migration must be a no-op
    // (NOT a "duplicate column" crash).
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Insert one existing task BEFORE applying the migration.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
        "VALUES ('wi_1', 'ws_1', 'chat')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) " ++
        "VALUES ('task_pre_065', 'Legacy task', 'wi_1')",
        &.{});

    try Migration065AddTaskHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by Backend.query — see project
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

    // Now stamp a unix-ms timestamp — should persist as the literal integer
    // (formatted as TEXT by Backend.bind). This is the exact call shape
    // that llm_history.updateTaskLastHumanTouchedAt will use.
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

const TestCtx066 = struct {
    db: Backend,
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // workspace_items + workspace_item_tasks: FK targets + chat-session table
    // that the backfill creates new rows in.
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

    // design_pages: the pre-migration shape (Migration 055 + 056 schema — id,
    // workspace_item_id, name, width, height, x, y, position, created_at,
    // updated_at, FK to workspace_items).
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
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("design_pages") ++
            \\
            \\WHERE name = 'workspace_item_task_id'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("design_pages") ++
        \\
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing066;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("workspace_item_task_id", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the "column
    // literally named TEXT" footgun from passing only a type to
    // addColumnIfMissing; see project memory
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (so the FK to
    // workspace_item_tasks.id works), not a literal "TEXT" string
    // in the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM 
        ++ comptime dialect.tableColumns("design_pages") ++
        \\
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
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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
    // …and a second time. Must not crash with "duplicate column name" or
    // "index already exists" — the `addColumnIfMissing` + `CREATE … IF NOT
    // EXISTS` calls are all idempotent.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("design_pages") ++
        \\
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

    // Simulate a fresh-DB install where the canonical CREATE TABLE for
    // design_pages already includes `workspace_item_task_id TEXT`.
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
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists,
    // CREATE INDEX IF NOT EXISTS is a no-op, backfill query returns
    // zero rows.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Re-check: still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("design_pages") ++
        \\
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

    // Seed: one workspace_item, then 3 design pages (with one empty-name edge
    // case to exercise the "Design Chat: untitled" fallback).
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

    // 1. Every page now has a non-NULL workspace_item_task_id that points at
    // a real workspace_item_tasks row.
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
    // The migration-registration trap: defining the struct is not enough — it
    // must also be added to `migration.zig::allMigrations`.
    for (allMigrations) |m| {
        if (m.version == Migration066AddDesignPageTaskFk.version) return;
    }
    return error.Migration066NotRegistered066;
}

// ===== Tests merged from migration_067_test.zig (2026-09-29 flatten) =====

// Static + behavioural regression checks for Migration 067
// (`workspace_item_tasks.tags`).

const TestCtx067 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb067() !TestCtx067 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // workspace_items (FK target for workspace_item_tasks.workspace_item_id)
    // and workspace_item_tasks itself must exist before the migration can
    // run.
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("workspace_item_tasks") ++
            \\
            \\WHERE name = 'tags'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration067AddTaskTags.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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
        \\SELECT type FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Simulate a fresh-DB install where the canonical CREATE TABLE already
    // includes `tags TEXT`. The migration must be a no-op (NOT a "duplicate
    // column" crash).
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Insert one existing task BEFORE applying the migration.
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
    // Catches the silent-skip regression where the struct is defined but the
    // registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration067AddTaskTags.version) return;
    }
    return error.Migration067NotRegistered067;
}

// ===== Tests merged from migration_068_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 068 (`llm_history.is_loading` +
// UNIQUE INDEX on `tool_call_id`).

const TestCtx068 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb068() !TestCtx068 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal `llm_history` schema matching the v1 shape — no `is_loading`
    // column yet (that's exactly what the migration adds).
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("llm_history") ++
            \\
            \\WHERE name = 'is_loading'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration068AddToolCallLoading.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("llm_history") ++
        \\
        \\WHERE name = 'is_loading'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing068;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_loading", row.values[0]);

    // Type sanity: the column must be INTEGER (NOT NULL DEFAULT 0).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM 
        ++ comptime dialect.tableColumns("llm_history") ++
        \\
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
        \\SELECT name, sql FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("llm_history") ++
        \\
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

    // Insert one existing row BEFORE applying the migration. Every historical
    // row was either written directly (not loading) or pre-existed; the
    // migration MUST backfill is_loading = 0 for every row.
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

    // Two rows with the SAME tool_call_id must be rejected. The assistant
    // message has tool_call_id = '' (not the placeholder's id), but the index
    // is partial so the assistant row passes through unaffected.
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

    // But a row with tool_call_id = '' (the assistant message shape) is
    // allowed — the partial WHERE clause excludes it. Insert a SECOND row
    // with tool_call_id = '' to prove the partial index is correctly scoped.
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
    // Catches the silent-skip regression where the struct is defined but the
    // registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration068AddToolCallLoading.version) return;
    }
    return error.Migration068NotRegistered068;
}

// ===== Tests merged from migration_069_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 069
// (`workspace_item_tasks.image_urls`).

const TestCtx069 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb069() !TestCtx069 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-069
    // shape — no `image_urls` column yet (that's exactly what the migration
    // adds).
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("workspace_item_tasks") ++
            \\
            \\WHERE name = 'image_urls'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration069AddTaskImageUrls.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
        \\WHERE name = 'image_urls'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing069;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("image_urls", row.values[0]);

    // Type + nullability + default sanity: the column must be TEXT NOT NULL
    // DEFAULT '' (the canonical "no images" sentinel — matches the
    // `description` / `tags` patterns from Migrations 062 / 067).
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
        \\WHERE name = 'image_urls'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing069;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no images"
    // sentinel). `pragma_table_info` reports it as the SQL literal text (i.e.
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Insert one existing row BEFORE applying the migration.
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
    // `llm_history.image_url` uses).
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
    // Catches the silent-skip regression where the struct is defined but the
    // registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration069AddTaskImageUrls.version) return;
    }
    return error.Migration069NotRegistered069;
}

// ===== Tests merged from migration_070_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 070 (`agent_memories` table +
// `agent_memories_fts` FTS5 virtual table).

/// Test fixture.

const TestCtx070 = struct {
    db: Backend,
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    return .{ .db = db, .threaded = threaded };
}

test "Migration070 creates agent_memories table with correct columns" {
    // After migration, `" ++ comptime dialect.tableColumns("agent_memories") ++ "` must show
    // columns: id (TEXT PK), content (TEXT NOT NULL), tags (TEXT NOT NULL
    // DEFAULT ''), created_at (DATETIME DEFAULT CURRENT_TIMESTAMP),
    const alloc = testing.allocator;
    var ctx = try setupDb070();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_memories'",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_memories'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.AgentMemoriesTableNotCreated070;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("agent_memories", row.values[0]);
    }

    // Verify the 5 expected columns exist with the expected names.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM " ++ comptime dialect.tableColumns("agent_memories") ++ " ORDER BY cid",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_memories'",
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
        "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='agent_memories_fts'",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='trigger' AND tbl_name='agent_memories'",
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
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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
    // Catches the silent-skip regression where the struct is defined but the
    // registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration070AddAgentMemories.version) return;
    }
    return error.Migration070NotRegistered070;
}

// ===== Tests merged from migration_071_test.zig (2026-09-29 flatten) =====

// Behavioural regression checks for Migration 071
// (`workspace_item_tasks.cwd`).

const TestCtx071 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

fn setupDb071() !TestCtx071 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    // Minimal `workspace_item_tasks` schema matching the pre-Migration-070
    // shape — no `cwd` column yet (that's exactly what the migration adds).
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
    // Minimal `workspace_items` table so the FK target exists for round-trip
    // tests that need to INSERT a parent row first.
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("workspace_item_tasks") ++
            \\
            \\WHERE name = 'cwd'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration071AddTaskCwd.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
        \\WHERE name = 'cwd'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing071;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("cwd", row.values[0]);

    // Type + nullability + default sanity: the column must be TEXT NOT NULL
    // DEFAULT '' (the canonical "no per-task cwd" sentinel — matches the
    // `description` / `tags` / `image_urls` patterns from Migrations 062 /
    var qt = try ctx.db.query(alloc,
        \\SELECT type, "notnull", dflt_value
        \\FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
        \\WHERE name = 'cwd'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing071;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);
    // "notnull" is 1 when NOT NULL.
    try testing.expectEqualStrings("1", type_row.values[1]);
    // Default value is the SQL `''` literal (the canonical "no per-task cwd"
    // sentinel). `pragma_table_info` reports it as the SQL literal text (i.e.
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

    // Insert one existing row BEFORE applying the migration.
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
    // Catches the silent-skip regression where the struct is defined but the
    // registration tuple is missing (per project memory
    // `migration-registration-trap`).
    const all = allMigrations;
    for (all) |m| {
        if (m.version == Migration071AddTaskCwd.version) return;
    }
    return error.Migration071NotRegistered071;
}

// ─── createWorkspaceItemTask round-trip tests (Migration 071) ───────────
// These tests exercise the model's createWorkspaceItemTask function (the
// canonical INSERT path for new tasks) to lock in the contract: the new `cwd`

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
        null,
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
        null,
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
        null,
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

// Helper for the round-trip tests above — inserts a minimal workspace_item
// row so the FK constraint on workspace_item_tasks.workspace_item_id is
// satisfied.
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

// Behavioural regression checks for Migration 072 (`workspace_item_tasks` →
// `kanban` table extraction).

const TestCtx072 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Set up a pre-Migration-072 in-memory DB — mirrors the schema a real
/// production user has after walking migrations 001 → 071.
fn setupDb072() !TestCtx072 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
test "Migration072 kanban_column_id FK is ON DELETE CASCADE — deleting a column un-places its task" {
    const alloc = testing.allocator;
    var ctx = try setupDb072();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // NB: PRAGMA foreign_keys is deliberately OFF in this project's
    // Backend init (see src/ai_workflow/tui/kanban_model.zig:306 for
    // the rationale — application code simulates CASCADE manually).
    if (dialect.enable_foreign_keys.len > 0) try ctx.db.exec(alloc, dialect.enable_foreign_keys, &.{});

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

    // Action: delete the column. With ON DELETE CASCADE this should silently
    // cascade-delete the kanban row. With the buggy ON DELETE SET NULL, this
    // would fail with `NOT NULL constraint failed: kanban.kanban_column_id`.
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
            \\SELECT 1 FROM 
            ++ dialect.tables_source ++
            \\
            \\WHERE type = 'table' AND name = 'kanban'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration072ExtractKanbanTable.up(&ctx.db, alloc);

    // Confirm the kanban table exists.
    var q = try ctx.db.query(alloc,
        \\SELECT 1 FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT 1 FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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
        \\SELECT 1 FROM 
        ++ dialect.tables_source ++
        \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("workspace_item_tasks") ++
        \\
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

// Behavioural regression checks for Migration 073 (`session_activity`
// append-only log).

const TestCtx073 = struct {
    db: Backend,
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration creates the `session_activity` table with the right
// columns in the right order.

test "Migration073 creates session_activity table with correct columns" {
    // After migration, `" ++ comptime dialect.tableColumns("session_activity") ++ "` must show
    // columns in order: id (TEXT PK), session_id (TEXT NOT NULL), description
    // (TEXT NOT NULL), created_at (DATETIME DEFAULT CURRENT_TIMESTAMP).
    const alloc = testing.allocator;
    var ctx = try setupDb073();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: table does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='session_activity'",
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
            "SELECT name FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='session_activity'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.SessionActivityTableNotCreated073;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("session_activity", row.values[0]);
    }

    // Verify the 4 expected columns exist with the expected names + order.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM " ++ comptime dialect.tableColumns("session_activity") ++ " ORDER BY cid",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type='table' AND name='session_activity'",
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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type='index' AND name='idx_session_activity_session_created'",
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
        \\SELECT name FROM 
        ++ dialect.tables_source ++
        \\
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

const TestCtx074 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 074.
/// After this returns, the schema is exactly what a production DB looks like
/// after Migration 074 has run — including the 2 cache-breakdown columns.
fn setupDb074() !TestCtx074 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — Migration adds the 2 columns with the right name + type + default
// 0.

test "Migration074 adds cache_creation_input_tokens + cache_read_input_tokens to llm_history" {
    const alloc = testing.allocator;
    var ctx = try setupDb074();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Post-migration: both columns exist with type=INTEGER and dflt_value=0.
    var q = try ctx.db.query(alloc,
        "SELECT name, type, dflt_value FROM " ++ comptime dialect.tableColumns("llm_history") ++ " " ++
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
// Test 2 — Idempotent on re-run.

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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("llm_history") ++ " " ++
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
// Test 3 — Legacy-style INSERTs that OMIT the cache columns still succeed
// with default 0 backfill.

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

// Behavioural regression checks for Migration 075 (rename 5 timestamp columns
// to `_nano` suffix).

const TestCtx075 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 074.
/// After this returns, the schema is exactly what a production DB looks like
/// after Migration 074 has run — BEFORE Migration 075's rename.
fn setupDb075() !TestCtx075 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

    var manager = MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try registerAllMigrations(&manager);
    try manager.runMigrations();

    // Seed one row in each affected table so the data-preservation tests have
    // something to verify against.
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

fn trySeed075(alloc: std.mem.Allocator, db: *Backend, sql: []const u8, argv: []const []const u8, table_name: []const u8) void {
    db.exec(alloc, sql, argv) catch |err| {
        std.debug.print("FAIL seed {s}: {s}\n", .{ table_name, @errorName(err) });
    };
}

/// Returns the list of column names on `table` (via pragma_table_info).
/// Caller owns the returned slice. Each element is allocated via `alloc.dupe`
/// and the slice itself is heap-allocated — both must be freed.
fn listColumns075(alloc: std.mem.Allocator, db: *Backend, table: []const u8) ![]const []u8 {
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
// Test 2 — Data preserved across the rename (llm_history only — the other
// tables use the same migration_064_test.zig setup pattern, see README in

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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_logs_created_at'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_logs_created_at_nano'",
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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_worker_last_activity'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_worker_last_activity_nano'",
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
            "SELECT 1 FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_llm_history_session_created'",
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
        "SELECT COUNT(*) FROM " ++ comptime dialect.tableColumns("llm_history") ++ " " ++
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
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
        "SELECT 1 FROM " ++ comptime dialect.tableColumns("llm_history") ++ " WHERE name = 'created_at_nano'",
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

// Behavioural regression checks for Migration 077 (users + user_companies +
// user_company_members + workspaces.user_id + sessions.user_id + default
// user_system + backfill).

const TestCtx077 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 077.
fn setupDb077() !TestCtx077 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);

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
    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "email", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "''" },
        .{ .name = "password_hash", .type = "TEXT", .default = "" },
        .{ .name = "role", .type = "TEXT", .default = "'user'" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "TIMESTAMP", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "TIMESTAMP", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "last_login_at", .type = "TIMESTAMP", .default = "" },
        .{ .name = "config_json", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM 
        ++ comptime dialect.tableColumns("users") ++
        \\ ORDER BY cid
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
        .{ .name = "created_at", .type = "TIMESTAMP", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "TIMESTAMP", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "created_by", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM 
        ++ comptime dialect.tableColumns("user_companies") ++
        \\ ORDER BY cid
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("user_company_members") ++
        \\ ORDER BY cid
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
    // place.
    var pk_q = try ctx.db.query(alloc,
        \\SELECT name, pk FROM 
        ++ comptime dialect.tableColumns("user_company_members") ++
        \\
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
    // Valid value: insert succeeds.
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
        \\SELECT type, "notnull" FROM 
        ++ comptime dialect.tableColumns("workspaces") ++
        \\
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
        // NULL is represented as an empty string by Backend.exec,
        // matching the project convention (see project memory
        // `sqlite-backend-empty-slice-binds-as-null`).
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration.
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
        \\SELECT type, "notnull" FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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

    // Run .up() three more times — each must NOT crash with "duplicate column
    // name" or "UNIQUE constraint failed" or any other error.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 4 runs total
    // (1 from setupDb + 3 from this test).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("workspaces") ++
        \\ WHERE name = 'user_id'
    , &.{});
    defer q.deinit();
    const ws_row = (try q.next()) orelse return error.RowMissing077;
    defer ws_row.deinit(alloc);
    try testing.expectEqualStrings("1", ws_row.values[0]);

    var q2 = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\ WHERE name = 'user_id'
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
// Test 8 — Migration 077 is registered in `allMigrations`.

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

const TestCtx082 = struct {
    db: Backend,
    threaded: std.Io.Threaded,
};

/// Minimal `sessions` table mirror matching the v17 production shape (no
/// `last_human_touched_at_nano` column yet, that's exactly what the migration
/// adds).
fn setupDb082() !TestCtx082 {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: Backend = .{};
    errdefer db.deinit();
    try test_db.openMemory(&db, io);
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
            \\SELECT 1 FROM 
            ++ comptime dialect.tableColumns("sessions") ++
            \\
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
        \\SELECT name FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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
        \\SELECT type FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing082;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);

    // Nullability sanity: NOT NULL must NOT appear in the column's
    // constraints (the canonical "never touched" state is NULL).
    var qn = try ctx.db.query(alloc,
        \\SELECT "notnull" FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    last_human_touched_at_nano INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM 
        ++ comptime dialect.tableColumns("sessions") ++
        \\
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

    // Insert one existing session BEFORE applying the migration.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_082', 'Legacy chat')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by Backend.query — same
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

    // Now stamp a unix-ms timestamp — should persist as the literal integer
    // (formatted as TEXT by Backend.bind). This is the exact call shape
    // that llm_history.updateSessionLastHumanTouchedAt will use.
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name IN ('idx_session_skill_events_session', 'idx_session_skill_events_skill')",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = 'session_skill_events'",
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
            "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = ?",
            &.{table});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }

    var qi = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name IN ('uq_skill_eval_facts','idx_skill_eval_facts_skill','uq_skill_eval_runs_self_prompt','idx_skill_eval_runs_session','idx_skill_eval_runs_status','idx_skill_eval_results_run','idx_skill_eval_results_skill','idx_skill_eval_results_session')",
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
        "SELECT COALESCE(user_id, '<null>') FROM skill_eval_runs WHERE id = ?",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name LIKE 'skill_eval_%'",
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

    // Omit `format` entirely so the schema DEFAULT applies.
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


// Migration 100 — `workspace_members` (shared workspaces) — inline tests
// ============================================================================

/// Minimal pre-100 schema: just a `workspaces` table carrying `user_id`
/// exactly as Migration 077 left it.
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
        "SELECT COALESCE(sql, '') FROM " ++ dialect.tables_source ++ " WHERE type = 'table' AND name = ?",
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

    // `user_id` MUST be NOT NULL.
    var q = try ctx.db.query(
        alloc,
        "SELECT type, \"notnull\" FROM " ++ comptime dialect.tableColumns("workspace_members") ++ " WHERE name = 'user_id'",
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
        "SELECT name FROM " ++ comptime dialect.tableColumns("workspace_members") ++ " WHERE pk > 0 ORDER BY pk",
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
        "SELECT COUNT(*) FROM " ++ dialect.tables_source ++ " WHERE type = 'index' AND name = 'idx_workspace_members_user'",
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


// ============================================================================
// Migration 101 — the `skills` table: workspace-scoped skill bodies.
// ============================================================================

// ============================================================================
// Migration 103 — `workspace_secrets`
// ============================================================================


// Migration 101 — inline tests
// ============================================================================
// Each case answers one question a reviewer must agree with before shipping:

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
        "id", "workspace_id", "name", "description", "content", "created_at", "updated_at", "is_can_auto_improve",
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
    // `COALESCE(NULLIF(?, ''), '')`.
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
// Migration 109 tests
// ============================================================================

/// The `skills` table exactly as Migration 102 shipped it, before 109. A
/// pre-109 database has this and no `is_can_auto_improve`.
fn createLegacySkillsTable(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE skills (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '',
        \\    content TEXT NOT NULL DEFAULT '',
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    UNIQUE (workspace_id, name)
        \\)
    , &.{});
}

fn autoImproveFlagOf(ctx: *TestCtx, id: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT is_can_auto_improve FROM skills WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "Migration109 adds the auto-improve column to a legacy skills table, defaulting to 1" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacySkillsTable(&ctx);
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name, content) VALUES ('sk_legacy', 'ws_a', 'pdf', 'body')
    , &.{});

    try Migration109AddSkillCanAutoImprove.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "skills");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_id", "name", "description", "content", "created_at", "updated_at", "is_can_auto_improve",
    });

    // A skill that existed before the column may be auto-improved: the
    // default has to be the permissive one, or every installed skill would
    // silently freeze the moment this migration ran.
    const flag = try autoImproveFlagOf(&ctx, "sk_legacy");
    defer alloc.free(flag);
    try testing.expectEqualStrings("1", flag);
}

test "Migration109 replaying does not reset a skill that was already locked" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacySkillsTable(&ctx);
    try ctx.db.exec(alloc,
        \\INSERT INTO skills (id, workspace_id, name, content) VALUES ('sk_locked', 'ws_a', 'pdf', 'body')
    , &.{});
    try Migration109AddSkillCanAutoImprove.up(&ctx.db, alloc);

    try ctx.db.exec(alloc, "UPDATE skills SET is_can_auto_improve = 0 WHERE id = 'sk_locked'", &.{});
    try Migration109AddSkillCanAutoImprove.up(&ctx.db, alloc);

    // `addColumnIfMissing` must not re-declare the column, because a second
    // ADD COLUMN is how a human's lock would be thrown away on every boot.
    const flag = try autoImproveFlagOf(&ctx, "sk_locked");
    defer alloc.free(flag);
    try testing.expectEqualStrings("0", flag);
}

test "Migration109 is a no-op on a table Migration102 already built with the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration102CreateSkills.up(&ctx.db, alloc);
    try Migration109AddSkillCanAutoImprove.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "skills");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // A fresh database runs BOTH, so the column must appear exactly once.
    try expectColumnsEqual(cols, &[_][]const u8{
        "id", "workspace_id", "name", "description", "content", "created_at", "updated_at", "is_can_auto_improve",
    });
}

test "Migration109 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration109AddSkillCanAutoImprove.version) return;
    }
    return error.Migration109NotRegistered;
}


// ============================================================================
// Migration 103 tests
// ============================================================================

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
    // owner column above all — fails the assertion above.
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

    // Same name, SAME workspace: rejected.
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
    var saw_owner = false;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "owner")) saw_owner = true;
    }
    try testing.expect(saw_owner);
}

test "Migration106 creates the model catalog tables with the agreed columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration106CreateModelCatalog.up(&ctx.db, alloc);

    const provider_cols = try columnsOf(&ctx, "model_catalog_providers");
    defer {
        for (provider_cols) |c| alloc.free(c);
        alloc.free(provider_cols);
    }
    try expectColumnsEqual(provider_cols, &[_][]const u8{ "id", "name", "base_url", "url_style", "env_json" });

    const model_cols = try columnsOf(&ctx, "model_catalog_models");
    defer {
        for (model_cols) |c| alloc.free(c);
        alloc.free(model_cols);
    }
    try expectColumnsEqual(model_cols, &[_][]const u8{
        "provider_id",     "model_id",  "name",   "context_window", "output_tokens",
        "reasoning",       "effort_json", "budget_min", "temperature", "cost_input",
        "cost_output",
    });

    const meta_cols = try columnsOf(&ctx, "model_catalog_meta");
    defer {
        for (meta_cols) |c| alloc.free(c);
        alloc.free(meta_cols);
    }
    try expectColumnsEqual(meta_cols, &[_][]const u8{
        "id", "schema_version", "source", "fetched_at_ms", "provider_count", "model_count",
    });
}

test "Migration106's text columns are NULLABLE so an empty base_url is representable" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration106CreateModelCatalog.up(&ctx.db, alloc);

    // THE LANDMINE THIS PINS: this backend binds an empty slice as SQL NULL,
    // and 25 of 227 providers (anthropic among them) have no `api` URL.
    for ([_][]const u8{ "base_url", "url_style", "name" }) |col| {
        const sql = try std.fmt.allocPrint(
            alloc,
            "SELECT \"notnull\" FROM " ++ comptime dialect.tableColumns("model_catalog_providers") ++ " WHERE name = '{s}'",
            .{col},
        );
        defer alloc.free(sql);
        var q = try ctx.db.query(alloc, sql, &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.ColumnMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }
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
        "SELECT \"notnull\" FROM " ++ comptime dialect.tableColumns("workspace_settings") ++ " WHERE name = 'config_json'",
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

// =============================================================================
// Migration 110 — `workspace_item_tasks.skill_name`
// =============================================================================

/// Minimal `workspace_item_tasks` as it existed BEFORE Migration 111: the
/// columns the earlier migrations added, minus `skill_name`. A legacy row
/// inserted here is what the migration has to survive.
fn createLegacyTasksTable110(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE IF NOT EXISTS workspace_item_tasks (
        \\  id TEXT PRIMARY KEY,
        \\  name TEXT NOT NULL,
        \\  workspace_item_id TEXT NOT NULL,
        \\  description TEXT NOT NULL DEFAULT '',
        \\  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\  task_type TEXT NOT NULL DEFAULT 'standard',
        \\  tags TEXT NOT NULL DEFAULT '',
        \\  image_urls TEXT NOT NULL DEFAULT '',
        \\  video_urls TEXT NOT NULL DEFAULT '',
        \\  cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
}

fn skillNameOf110(ctx: *TestCtx, id: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(skill_name, '') FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "Migration110 adds skill_name to a legacy tasks table, defaulting to ''" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id)
        \\VALUES ('t_legacy', 'Old task', 'item_1')
    , &.{});

    try Migration110AddTaskSkillName.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_item_tasks");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Appended last, so every pre-existing column keeps its index — the
    // listers' `row.values[N]` mapping depends on that.
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",         "name",     "workspace_item_id", "description", "created_at",
        "updated_at", "task_type", "tags",             "image_urls",  "video_urls",
        "cwd",        "skill_name",
    });

    // A task created before the column existed has no skill: the default
    // must be the empty sentinel, not NULL (the listers COALESCE, but a
    // NOT NULL column is what makes the empty string the only "no skill").
    const name = try skillNameOf110(&ctx, "t_legacy");
    defer alloc.free(name);
    try testing.expectEqualStrings("", name);
}

test "Migration110 replaying does not clobber a stored skill name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, skill_name)
        \\VALUES ('t_picked', 'New task', 'item_1', 'pdf')
    , &.{});

    // `addColumnIfMissing` must not re-declare the column: a second
    // ADD COLUMN is how a human's pick would be thrown away on every boot.
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);

    const name = try skillNameOf110(&ctx, "t_picked");
    defer alloc.free(name);
    try testing.expectEqualStrings("pdf", name);
}

test "Migration110 is a no-op on a table that already has the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_item_tasks");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Exactly one `skill_name` — a duplicate column is a hard SQLite error,
    // so a re-run that throws would break every boot after the first.
    var seen: usize = 0;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "skill_name")) seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "Migration110 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration110AddTaskSkillName.version) return;
    }
    return error.Migration110NotRegistered;
}

test "createWorkspaceItemTask: skill_names round-trips through the INSERT" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_skill",
        "Task with a skill",
        "item_1",
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        null, // cwd
        null, // video_urls
        "pdf", // skill_names (Migration 112)
    );
    defer task.deinit(alloc);

    // The returned struct mirrors what was INSERTed, so the caller's view
    // of the new task matches the DB without a round-trip SELECT.
    try testing.expectEqualStrings("pdf", task.skill_names);

    const stored = try skillNamesOf112(&ctx, "t_skill");
    defer alloc.free(stored);
    try testing.expectEqualStrings("pdf", stored);
}

test "createWorkspaceItemTask: several names reach the row as one ||-joined list" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_many_skills",
        "Task with several skills",
        "item_1",
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        null, // cwd
        null, // video_urls
        "pdf||zig-trap", // skill_names — the picker's order, preserved
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("pdf||zig-trap", task.skill_names);

    const stored = try skillNamesOf112(&ctx, "t_many_skills");
    defer alloc.free(stored);
    try testing.expectEqualStrings("pdf||zig-trap", stored);
}

test "createWorkspaceItemTask: skill_names = null stores the empty sentinel" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_no_skill",
        "Task without a skill",
        "item_1",
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        null, // cwd
        null, // video_urls
        null, // skill_names — the omitted-body-field case
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.skill_names);

    const stored = try skillNamesOf112(&ctx, "t_no_skill");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

test "createWorkspaceItemTask: skill_names = '' stores '' (not NULL)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    // The empty-slice-binds-as-NULL trap: `Backend.exec` binds "" as
    // NULL, so the dynamic-SQL builder MUST emit a `''` literal here or the
    // INSERT violates the NOT NULL constraint.
    const task = try createWorkspaceItemTask(
        alloc,
        &ctx.db,
        "t_empty_skill",
        "Task with an explicit empty skill",
        "item_1",
        "standard",
        null, // description
        null, // tags
        null, // image_urls
        null, // cwd
        null, // video_urls
        "", // skill_names — the frontend's canonical "no skill" sentinel
    );
    defer task.deinit(alloc);

    try testing.expectEqualStrings("", task.skill_names);

    const stored = try skillNamesOf112(&ctx, "t_empty_skill");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}


// ============================================================================
// Migration 112 tests — one task, several skills (`skill_name` -> `skill_names`)
// ============================================================================

/// Read the renamed column back, so a test can prove the RENAME kept the value
/// instead of dropping it.
fn skillNamesOf112(ctx: *TestCtx, id: []const u8) ![]const u8 {
    const alloc = testing.allocator;
    var q = try ctx.db.query(
        alloc,
        "SELECT COALESCE(skill_names, '') FROM workspace_item_tasks WHERE id = ?",
        &[_][]const u8{id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoRows;
    defer row.deinit(alloc);
    return alloc.dupe(u8, row.values[0]);
}

test "Migration112 renames skill_name and keeps the row's stored names" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    try ctx.db.exec(alloc,
        \\INSERT INTO workspace_item_tasks (id, name, workspace_item_id, skill_name)
        \\VALUES ('t_picked', 'Task with a skill', 'item_1', 'pdf')
    , &.{});

    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_item_tasks");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    // Same position as the column 110 appended: the listers map
    // `row.values[N]`, so a rename that moved it would break them.
    try expectColumnsEqual(cols, &[_][]const u8{
        "id",           "name",     "workspace_item_id", "description", "created_at",
        "updated_at",   "task_type", "tags",             "image_urls",  "video_urls",
        "cwd",          "skill_names",
    });

    const names = try skillNamesOf112(&ctx, "t_picked");
    defer alloc.free(names);
    try testing.expectEqualStrings("pdf", names);
}

test "Migration112 replaying is a no-op: one skill_names, no skill_name" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyTasksTable110(&ctx);
    try Migration110AddTaskSkillName.up(&ctx.db, alloc);
    // Every boot after the first re-runs it: a second RENAME on a table that
    // already has the new name must not throw.
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);
    try Migration112RenameTaskSkillNames.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "workspace_item_tasks");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    var renamed: usize = 0;
    var original: usize = 0;
    for (cols) |c| {
        if (std.mem.eql(u8, c, "skill_names")) renamed += 1;
        if (std.mem.eql(u8, c, "skill_name")) original += 1;
    }
    try testing.expectEqual(@as(usize, 1), renamed);
    try testing.expectEqual(@as(usize, 0), original);
}

test "Migration112 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration112RenameTaskSkillNames.version) return;
    }
    return error.Migration112NotRegistered;
}



// ============================================================================
// Migration 111 tests — kanban task dependencies + `kanban_columns.is_done`
// ============================================================================

/// The kanban_columns shape Migration 051 created, WITHOUT `is_done` — what a
/// real pre-111 database looks like.
fn createLegacyKanbanColumns(ctx: *TestCtx) !void {
    const alloc = testing.allocator;
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '', position INTEGER,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
}

fn isDoneOf(ctx: *TestCtx, column_id: []const u8) !bool {
    const alloc = testing.allocator;
    var q = try ctx.db.query(alloc,
        "SELECT is_done FROM kanban_columns WHERE id = ?", &.{column_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    return !std.mem.eql(u8, row.values[0], "0");
}

test "Migration111 creates the dependency table with a composite primary key" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyKanbanColumns(&ctx);
    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);

    const cols = try columnsOf(&ctx, "kanban_task_dependencies");
    defer {
        for (cols) |c| alloc.free(c);
        alloc.free(cols);
    }
    try expectColumnsEqual(cols, &[_][]const u8{
        "task_id", "depends_on_task_id", "created_at",
    });

    // The composite key is what makes a duplicate edge impossible — a
    // duplicate would double-count a dependency in every blocker list.
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_task_dependencies (task_id, depends_on_task_id) VALUES ('t1', 't2')", &.{});
    try testing.expectError(error.ExecuteFailed, ctx.db.exec(alloc,
        "INSERT INTO kanban_task_dependencies (task_id, depends_on_task_id) VALUES ('t1', 't2')", &.{}));
}

test "Migration111 adds is_done and backfills the columns that complete a task" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyKanbanColumns(&ctx);
    // The board this feature was filed on: the LAST column is `drop`, which is
    // exactly why "the last column is done" cannot be the rule.
    try ctx.db.exec(alloc,
        \\INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES
        \\ ('c1', 'item_1', 'todo', 0), ('c2', 'item_1', 'in progress', 1),
        \\ ('c3', 'item_1', 'merged', 2), ('c4', 'item_1', 'on_hold', 3),
        \\ ('c5', 'item_1', 'drop', 4)
    , &.{});

    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);

    try testing.expect(!try isDoneOf(&ctx, "c1"));
    try testing.expect(!try isDoneOf(&ctx, "c2"));
    try testing.expect(try isDoneOf(&ctx, "c3"));
    try testing.expect(!try isDoneOf(&ctx, "c4"));
    try testing.expect(try isDoneOf(&ctx, "c5"));
}

test "Migration111 falls back to the last column when no name matches" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyKanbanColumns(&ctx);
    // Neither board names a completing column. Without the fallback every
    // dependency on these boards would block forever.
    try ctx.db.exec(alloc,
        \\INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES
        \\ ('a1', 'item_a', 'antrian', 0), ('a2', 'item_a', 'dikerjakan', 1),
        \\ ('b1', 'item_b', 'backlog', 0), ('b2', 'item_b', 'review', 1),
        \\ ('b3', 'item_b', 'shipped', 2)
    , &.{});

    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);

    // item_a: nothing matched, so its LAST column is the fallback.
    try testing.expect(!try isDoneOf(&ctx, "a1"));
    try testing.expect(try isDoneOf(&ctx, "a2"));
    // item_b already matched on `shipped`, so the fallback must NOT also flag
    // `review` — a board has exactly one completing column here.
    try testing.expect(!try isDoneOf(&ctx, "b1"));
    try testing.expect(!try isDoneOf(&ctx, "b2"));
    try testing.expect(try isDoneOf(&ctx, "b3"));
}

test "Migration111 replaying does not re-flag a column the user switched off" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try createLegacyKanbanColumns(&ctx);
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'done', 0)", &.{});

    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);
    try testing.expect(try isDoneOf(&ctx, "c1"));

    // The user decides `done` is NOT where work finishes.
    try ctx.db.exec(alloc, "UPDATE kanban_columns SET is_done = 0 WHERE id = 'c1'", &.{});

    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);
    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);

    try testing.expect(!try isDoneOf(&ctx, "c1"));
}

test "Migration111 is a no-op on a table that already has is_done" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Fresh-install shape: `is_done` is already there (Migration 051's
    // CREATE TABLE plus every fixture), and there is nothing to backfill.
    try ctx.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT NOT NULL,
        \\    description TEXT NOT NULL DEFAULT '', position INTEGER,
        \\    is_done INTEGER NOT NULL DEFAULT 0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position, is_done) VALUES ('c1', 'item_1', 'Todo', 0, 0)", &.{});

    try Migration111AddKanbanTaskDependencies.up(&ctx.db, alloc);

    // `Todo` is not a completing name, and the column existed before this
    // migration, so the backfill never ran.
    try testing.expect(!try isDoneOf(&ctx, "c1"));
}

test "Migration111 is registered in allMigrations" {
    for (allMigrations) |m| {
        if (m.version == Migration111AddKanbanTaskDependencies.version) return;
    }
    return error.Migration111NotRegistered;
}

package com.pabrik.mobile.sync

data class SyncFeature(
    val id: String,
    val entityType: String,
    val mergePolicy: String,
    val supportsDelete: Boolean,
)

object SyncRegistry {
    const val POLICY_LWW = "lww"

    val FEATURES: List<SyncFeature> = listOf(
        SyncFeature("workspaces", "workspace", POLICY_LWW, supportsDelete = true),
        SyncFeature("items", "item", POLICY_LWW, supportsDelete = true),
        SyncFeature("kanban", "kanban_task", POLICY_LWW, supportsDelete = true),
        SyncFeature("chat", "chat", POLICY_LWW, supportsDelete = true),
        SyncFeature("design", "design_element", POLICY_LWW, supportsDelete = true),
        SyncFeature("agent", "agent", POLICY_LWW, supportsDelete = true),
        SyncFeature("routine", "routine", POLICY_LWW, supportsDelete = true),
        SyncFeature("documents", "document", POLICY_LWW, supportsDelete = true),
        SyncFeature("settings", "setting", POLICY_LWW, supportsDelete = false),
    )

    fun forEntityType(entityType: String): SyncFeature? =
        FEATURES.firstOrNull { it.entityType == entityType }

    fun isSyncable(entityType: String): Boolean = forEntityType(entityType) != null

    fun mergePolicyFor(entityType: String): String =
        forEntityType(entityType)?.mergePolicy ?: POLICY_LWW

    fun supportsDelete(entityType: String): Boolean =
        forEntityType(entityType)?.supportsDelete ?: false

    fun outboxOperation(isDelete: Boolean, exists: Boolean): String = when {
        isDelete -> "delete"
        exists -> "update"
        else -> "create"
    }

    fun syncKey(entityType: String, id: String): String = "$entityType:$id"
}

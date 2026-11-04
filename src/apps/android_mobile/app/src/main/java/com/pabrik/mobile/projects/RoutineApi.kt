package com.pabrik.mobile.projects

import com.pabrik.mobile.network.UriEncoding
import com.pabrik.mobile.recents.stringField
import org.json.JSONObject

data class WorkspaceRoutine(
    val id: String,
    val workspaceItemId: String,
    val description: String,
    val instruction: String,
    val schedule: String,
    val selectedProfileModel: String,
    val enabled: Boolean,
    val lastRunAt: String,
    val nextRunAt: String,
    val lastStatus: String,
    val lastError: String,
    val createdAt: String,
    val updatedAt: String,
) {
    val isManualOnly: Boolean get() = schedule.trim().isEmpty()
    val hasRun: Boolean get() = lastStatus.isNotBlank()
}

data class RoutinePreset(val label: String, val cron: String)

object RoutinePresets {
    const val CRON_FIELDS = "minute hour day-of-month month day-of-week"

    val ALL: List<RoutinePreset> = listOf(
        RoutinePreset("Manual only", ""),
        RoutinePreset("Every hour", "0 * * * *"),
        RoutinePreset("Daily 09:00", "0 9 * * *"),
        RoutinePreset("Weekdays 09:00", "0 9 * * 1-5"),
    )

    fun forCron(cron: String): RoutinePreset? {
        val trimmed = cron.trim()
        return ALL.firstOrNull { it.cron == trimmed }
    }
}

object RoutineCron {
    private val FIELD_CHARS = Regex("^[0-9*,\\-/]+$")

    fun validate(expr: String): String? {
        val trimmed = expr.trim()
        if (trimmed.isEmpty()) return null
        val fields = trimmed.split(Regex("\\s+"))
        if (fields.size != 5) {
            return "Schedule must have exactly 5 fields (${RoutinePresets.CRON_FIELDS}), or be empty for manual-only"
        }
        for (field in fields) {
            if (!FIELD_CHARS.matches(field)) return "Invalid schedule field: \"$field\""
        }
        return null
    }

    fun isValid(expr: String): Boolean = validate(expr) == null
}

object RoutineApi {

    fun createPath(workspaceId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/routine")
    }

    fun routinePath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/routine")
    }

    fun runPath(workspaceId: String, itemId: String, routineId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
        append("/routines/")
        append(UriEncoding.encode(routineId))
        append("/run")
    }

    fun deleteItemPath(workspaceId: String, itemId: String): String = buildString {
        append("/api/workspaces/")
        append(UriEncoding.encode(workspaceId))
        append("/items/")
        append(UriEncoding.encode(itemId))
    }

    fun createBody(
        name: String,
        path: String,
        description: String = "",
        instruction: String = "",
        schedule: String = "",
        enabled: Boolean = true,
    ): String {
        val json = JSONObject()
        json.put("name", name.trim())
        json.put("path", path)
        json.put("description", description)
        json.put("instruction", instruction)
        json.put("schedule", schedule.trim())
        json.put("enabled", enabled)
        return json.toString()
    }

    fun updateBody(
        description: String? = null,
        instruction: String? = null,
        schedule: String? = null,
        selectedProfileModel: String? = null,
        enabled: Boolean? = null,
    ): String {
        val json = JSONObject()
        if (description != null) json.put("description", description)
        if (instruction != null) json.put("instruction", instruction)
        if (schedule != null) json.put("schedule", schedule.trim())
        if (selectedProfileModel != null) json.put("selected_profile_model", selectedProfileModel)
        if (enabled != null) json.put("enabled", enabled)
        return json.toString()
    }

    fun parseRoutine(body: String): WorkspaceRoutine? {
        val root = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        val routine = root.optJSONObject("routine") ?: return null
        return parseRoutineObject(routine)
    }

    fun parseCreatedRoutine(body: String): Pair<ProjectSummary, WorkspaceRoutine>? {
        val root = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        val item = root.optJSONObject("item") ?: return null
        val routine = root.optJSONObject("routine") ?: return null
        val itemId = item.stringField("id")
        if (itemId.isEmpty()) return null
        val parsedRoutine = parseRoutineObject(routine) ?: return null
        val summary = ProjectSummary(
            id = itemId,
            workspaceId = item.stringField("workspace_id"),
            itemType = item.stringField("item_type").ifEmpty { ProjectTypes.ROUTINE },
            name = item.stringField("name"),
            path = item.stringField("path"),
        )
        return summary to parsedRoutine
    }

    fun parseRunSessionId(body: String): String? {
        val root = try {
            JSONObject(body)
        } catch (_: Exception) {
            return null
        }
        return root.stringField("session_id").ifEmpty { null }
    }

    private fun parseRoutineObject(routine: JSONObject): WorkspaceRoutine? {
        val id = routine.stringField("id")
        if (id.isEmpty()) return null
        return WorkspaceRoutine(
            id = id,
            workspaceItemId = routine.stringField("workspace_item_id"),
            description = routine.stringField("description"),
            instruction = routine.stringField("instruction"),
            schedule = routine.stringField("schedule"),
            selectedProfileModel = routine.stringField("selected_profile_model"),
            enabled = routine.optBoolean("enabled", false),
            lastRunAt = routine.stringField("last_run_at"),
            nextRunAt = routine.stringField("next_run_at"),
            lastStatus = routine.stringField("last_status"),
            lastError = routine.stringField("last_error"),
            createdAt = routine.stringField("created_at"),
            updatedAt = routine.stringField("updated_at"),
        )
    }
}

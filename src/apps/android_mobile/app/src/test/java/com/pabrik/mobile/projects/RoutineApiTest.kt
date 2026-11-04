package com.pabrik.mobile.projects

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutineApiTest {

    @Test
    fun createPathScopesToWorkspaceAndRoutineSegment() {
        assertEquals("/api/workspaces/ws_1/items/routine", RoutineApi.createPath("ws_1"))
    }

    @Test
    fun routinePathCarriesBothIds() {
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/routine",
            RoutineApi.routinePath("ws_1", "item_1"),
        )
    }

    @Test
    fun runPathUsesPluralRoutinesSegmentVerbatim() {
        assertEquals(
            "/api/workspaces/ws_1/items/item_1/routines/r_1/run",
            RoutineApi.runPath("ws_1", "item_1", "r_1"),
        )
    }

    @Test
    fun pathsEncodeIdsThatWouldSplitTheRoute() {
        val path = RoutineApi.routinePath("ws/1", "item 1")
        assertTrue(path, path.contains("ws%2F1"))
        assertTrue(path, path.contains("item%201"))
        assertFalse(path.contains("ws/1"))
    }

    @Test
    fun deleteItemPathIsTheGenericItemRoute() {
        assertEquals(
            "/api/workspaces/ws_1/items/item_1",
            RoutineApi.deleteItemPath("ws_1", "item_1"),
        )
    }

    @Test
    fun createBodySendsVueShapeWithTrimmedNameAndSchedule() {
        val body = JSONObject(
            RoutineApi.createBody(
                name = "  Nightly  ",
                path = "/tmp/routine",
                instruction = "Summarise issues",
                schedule = "  0 9 * * *  ",
            ),
        )
        assertEquals("Nightly", body.getString("name"))
        assertEquals("/tmp/routine", body.getString("path"))
        assertEquals("", body.getString("description"))
        assertEquals("Summarise issues", body.getString("instruction"))
        assertEquals("0 9 * * *", body.getString("schedule"))
        assertTrue(body.getBoolean("enabled"))
    }

    @Test
    fun createBodyDefaultsToManualOnlyEnabled() {
        val body = JSONObject(RoutineApi.createBody(name = "N", path = "/p"))
        assertEquals("", body.getString("schedule"))
        assertTrue(body.getBoolean("enabled"))
    }

    @Test
    fun updateBodyOmitsUnsetFields() {
        val body = JSONObject(RoutineApi.updateBody(schedule = "0 * * * *"))
        assertEquals("0 * * * *", body.getString("schedule"))
        assertFalse(body.has("description"))
        assertFalse(body.has("instruction"))
        assertFalse(body.has("selected_profile_model"))
        assertFalse(body.has("enabled"))
    }

    @Test
    fun updateBodySendsSelectedProfileModelSnakeCase() {
        val body = JSONObject(RoutineApi.updateBody(selectedProfileModel = "900ribu"))
        assertEquals("900ribu", body.getString("selected_profile_model"))
    }

    @Test
    fun parseRoutineReadsEveryField() {
        val routine = RoutineApi.parseRoutine(
            """{"routine":{"id":"r_1","workspace_item_id":"item_1","description":"d","instruction":"i","schedule":"0 9 * * *","selected_profile_model":"m","enabled":true,"last_run_at":"2026-11-04T10:00:00Z","next_run_at":"2026-11-05T09:00:00Z","last_status":"success","last_error":"","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-04T10:00:00Z"}}""",
        )
        assertNotNull(routine)
        assertEquals("r_1", routine!!.id)
        assertEquals("item_1", routine.workspaceItemId)
        assertEquals("d", routine.description)
        assertEquals("i", routine.instruction)
        assertEquals("0 9 * * *", routine.schedule)
        assertEquals("m", routine.selectedProfileModel)
        assertTrue(routine.enabled)
        assertEquals("2026-11-04T10:00:00Z", routine.lastRunAt)
        assertEquals("2026-11-05T09:00:00Z", routine.nextRunAt)
        assertEquals("success", routine.lastStatus)
        assertEquals("", routine.lastError)
        assertEquals("2026-11-01T00:00:00Z", routine.createdAt)
        assertEquals("2026-11-04T10:00:00Z", routine.updatedAt)
        assertFalse(routine.isManualOnly)
        assertTrue(routine.hasRun)
    }

    @Test
    fun parseRoutineMapsExplicitNullsToEmptyAndDisabled() {
        val routine = RoutineApi.parseRoutine(
            """{"routine":{"id":"r_1","workspace_item_id":null,"description":null,"instruction":null,"schedule":null,"selected_profile_model":null,"enabled":null,"last_run_at":null,"next_run_at":null,"last_status":null,"last_error":null,"created_at":null,"updated_at":null}}""",
        )
        assertNotNull(routine)
        assertEquals("", routine!!.workspaceItemId)
        assertEquals("", routine.description)
        assertEquals("", routine.schedule)
        assertFalse(routine.enabled)
        assertTrue(routine.isManualOnly)
        assertFalse(routine.hasRun)
    }

    @Test
    fun parseRoutineRefusesMissingEnvelopeAndMissingId() {
        assertNull(RoutineApi.parseRoutine("""{}"""))
        assertNull(RoutineApi.parseRoutine("""{"routine":{}}"""))
        assertNull(RoutineApi.parseRoutine("not json"))
    }

    @Test
    fun parseCreatedRoutineUnwrapsItemAndRoutine() {
        val parsed = RoutineApi.parseCreatedRoutine(
            """{"item":{"id":"item_1","workspace_id":"ws_1","item_type":"routine","name":"Nightly","path":"/tmp/routine"},"routine":{"id":"r_1","workspace_item_id":"item_1","description":"","instruction":"i","schedule":"","selected_profile_model":"","enabled":true,"last_run_at":"","next_run_at":"","last_status":"","last_error":"","created_at":"","updated_at":""}}""",
        )
        assertNotNull(parsed)
        assertEquals("item_1", parsed!!.first.id)
        assertEquals("ws_1", parsed.first.workspaceId)
        assertEquals(ProjectTypes.ROUTINE, parsed.first.itemType)
        assertEquals("Nightly", parsed.first.name)
        assertEquals("/tmp/routine", parsed.first.path)
        assertEquals("r_1", parsed.second.id)
        assertTrue(parsed.second.isManualOnly)
    }

    @Test
    fun parseCreatedRoutineRefusesMissingItemId() {
        assertNull(
            RoutineApi.parseCreatedRoutine(
                """{"item":{"id":"","workspace_id":"ws_1"},"routine":{"id":"r_1"}}""",
            ),
        )
    }

    @Test
    fun parseRunSessionIdReadsSessionId() {
        assertEquals("r_1", RoutineApi.parseRunSessionId("""{"session_id":"r_1"}"""))
        assertNull(RoutineApi.parseRunSessionId("""{}"""))
        assertNull(RoutineApi.parseRunSessionId("not json"))
    }

    @Test
    fun cronAcceptsEmptyAsManualOnly() {
        assertNull(RoutineCron.validate(""))
        assertNull(RoutineCron.validate("   "))
        assertTrue(RoutineCron.isValid(""))
    }

    @Test
    fun cronAcceptsFiveFieldExpressions() {
        assertNull(RoutineCron.validate("0 * * * *"))
        assertNull(RoutineCron.validate("0 9 * * 1-5"))
        assertNull(RoutineCron.validate("*/15 9-17 * * 1,3,5"))
        assertNull(RoutineCron.validate("  0   9  *  *  *  "))
    }

    @Test
    fun cronRejectsWrongFieldCount() {
        assertNotNull(RoutineCron.validate("0 9 * *"))
        assertNotNull(RoutineCron.validate("0 9 * * * *"))
        assertNotNull(RoutineCron.validate("0"))
    }

    @Test
    fun cronRejectsIllegalCharacters() {
        assertNotNull(RoutineCron.validate("0 9 * * MON"))
        assertNotNull(RoutineCron.validate("0 9 * * ?"))
        assertNotNull(RoutineCron.validate("0 9 * * 1#2"))
    }

    @Test
    fun presetsMatchVueExactly() {
        assertEquals(
            listOf(
                RoutinePreset("Manual only", ""),
                RoutinePreset("Every hour", "0 * * * *"),
                RoutinePreset("Daily 09:00", "0 9 * * *"),
                RoutinePreset("Weekdays 09:00", "0 9 * * 1-5"),
            ),
            RoutinePresets.ALL,
        )
        assertEquals("minute hour day-of-month month day-of-week", RoutinePresets.CRON_FIELDS)
    }

    @Test
    fun presetLookupTrimsAndMatches() {
        assertEquals("Every hour", RoutinePresets.forCron("  0 * * * *  ")?.label)
        assertEquals("Manual only", RoutinePresets.forCron("")?.label)
        assertNull(RoutinePresets.forCron("0 10 * * *"))
    }
}

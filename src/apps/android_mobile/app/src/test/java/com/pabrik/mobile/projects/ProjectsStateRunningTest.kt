package com.pabrik.mobile.projects

import com.pabrik.mobile.recents.ChatSummary
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Projects section's "something in here is working" indicator. */
class ProjectsStateRunningTest {

    private fun page(vararg ids: String) = ProjectChatsPage(
        chats = ids.map { id ->
            ProjectChat(
                id = id,
                projectId = "p",
                name = "Chat $id",
                updatedAtEpochMillis = 0L,
            )
        },
        hasMore = false,
        nextCursor = null,
    )

    private fun state(
        projects: List<String> = listOf("p1", "p2"),
        chats: Map<String, ProjectChatsPage> = emptyMap(),
    ) = ProjectsState(
        expanded = true,
        items = projects.map { id ->
            ProjectSummary(id = id, workspaceId = "ws_1", itemType = "kanban", name = id)
        },
        expandedItemIds = emptySet(),
        chats = chats,
        isLoading = false,
        errorMessage = null,
    )

    @Test
    fun aRunningChatMarksItsProject() {
        val projects = state(chats = mapOf("p1" to page("t1", "t2"), "p2" to page("t3")))

        assertEquals(setOf("p1"), projects.runningProjectIds(setOf("t2")))
    }

    @Test
    fun twoProjectsCanBeRunningAtOnce() {
        // The reported situation, restated at the level this class can see
        val projects = state(
            chats = mapOf("p1" to page("t1"), "p2" to page("t2", "t3")),
        )

        assertEquals(setOf("p1", "p2"), projects.runningProjectIds(setOf("t1", "t3")))
    }

    @Test
    fun anIdleWorkspaceLightsNothing() {
        val projects = state(chats = mapOf("p1" to page("t1"), "p2" to page("t2")))

        // Nothing in either project has a worker: the running set and the loaded task ids are disjoint, which is the whole negative case.
        assertTrue(projects.runningProjectIds(setOf("t9", "t10")).isEmpty())
        assertTrue(projects.runningProjectIds(emptySet()).isEmpty())
    }

    @Test
    fun aProjectWithNoLoadedChatsIsNeverMarked() {
        // The honest limit, and the reason this cannot lie: with nothing but a loaded page to go on, a folded project has no task ids here and so has nothing to check.
        val projects = state(chats = mapOf("p1" to page("t1")))

        assertTrue(projects.runningProjectIds(setOf("t2")).isEmpty())
    }

    @Test
    fun aRunningSessionNoClientHasLoadedLightsNothing() {
        val projects = state(chats = mapOf("p1" to page("t1")))

        assertTrue(projects.runningProjectIds(setOf("never-seen-1")).isEmpty())
    }

    // ── The recents carry the project, so a FOLDED row resolves ──────────

    private fun recents(vararg entries: Pair<String, String?>) = entries.map { (id, projectId) ->
        ChatSummary(
            id = id,
            workspaceId = "ws_1",
            title = "Chat $id",
            updatedAtEpochMillis = 0L,
            projectId = projectId,
        )
    }

    @Test
    fun aFoldedProjectResolvesFromTheRecents() {
        // No page loaded for either project — both are folded, which is the state the report was taken in.
        val projects = state()
        val recents = recents("t1" to "p1", "t2" to "p2")

        assertEquals(setOf("p2"), projects.runningProjectIds(setOf("t2"), recents))
    }

    @Test
    fun threeWorkersAcrossThreeFoldedProjectsAllLight() {
        // The report, restated at full size: three live workers, none of their projects ever unfolded.
        val projects = state(projects = listOf("p1", "p2", "p3"))
        val recents = recents("t1" to "p1", "t2" to "p2", "t3" to "p3")

        assertEquals(
            setOf("p1", "p2", "p3"),
            projects.runningProjectIds(setOf("t1", "t2", "t3"), recents),
        )
    }

    @Test
    fun bothSourcesTogetherAreOneSet() {
        // A project read from an unfolded page and one read from the recents must not collide into something stranger, and neither may be lost.
        val projects = state(chats = mapOf("p1" to page("t1")))
        val recents = recents("t2" to "p2")

        assertEquals(setOf("p1", "p2"), projects.runningProjectIds(setOf("t1", "t2"), recents))
    }

    @Test
    fun aRunningChatInNoProjectLightsNothing() {
        // The case that must not be "helpfully" attributed to some project.
        val projects = state()
        val recents = recents("t1" to null, "t2" to "")

        assertTrue(projects.runningProjectIds(setOf("t1", "t2"), recents).isEmpty())
    }

    @Test
    fun anIdleRecentsListLightsNothing() {
        val projects = state(chats = mapOf("p1" to page("t1")))
        val recents = recents("t1" to "p1")

        assertTrue(projects.runningProjectIds(emptySet(), recents).isEmpty())
        // And a running session absent from both sources stays dark.
        assertTrue(projects.runningProjectIds(setOf("t9"), recents).isEmpty())
    }
}

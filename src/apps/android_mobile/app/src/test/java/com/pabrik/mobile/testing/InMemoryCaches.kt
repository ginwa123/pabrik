package com.pabrik.mobile.testing

import com.pabrik.mobile.projects.ProjectsCache
import com.pabrik.mobile.projects.ProjectSummary
import com.pabrik.mobile.projects.ProjectChat
import com.pabrik.mobile.chat.CachedChatMessage
import com.pabrik.mobile.chat.ChatCache
import com.pabrik.mobile.chat.ChatOlderPage
import com.pabrik.mobile.recents.ChatSummary
import com.pabrik.mobile.recents.RecentsCache
import com.pabrik.mobile.recents.WorkspaceOption
import com.pabrik.mobile.storage.LastPosition
import com.pabrik.mobile.storage.LastPositionStore

/** In-memory stand-ins for the three caches, for the ViewModel tests. */
class InMemoryChatCache : ChatCache {
    private val rows = mutableMapOf<String, MutableMap<String, CachedChatMessage>>()
    private val cursors = mutableMapOf<String, String>()
    private val olderPages = mutableMapOf<String, ChatOlderPage>()

    var cleared = false
        private set

    override fun readMessages(
        userId: String?,
        sessionId: String,
        limit: Int,
    ): List<CachedChatMessage>? {
        val rows = rows[key(userId, sessionId)] ?: return null
        return rows.values
            .sortedWith(
                compareByDescending<CachedChatMessage> { it.sortKeyNanos }
                    .thenByDescending { it.id },
            )
            .take(limit.coerceAtLeast(1))
    }

    override fun writeMessages(
        userId: String?,
        sessionId: String,
        messages: List<CachedChatMessage>,
    ) {
        if (messages.isEmpty()) return
        val bucket = rows.getOrPut(key(userId, sessionId) ?: return) { mutableMapOf() }
        messages.forEach { bucket[it.id] = it }
    }

    override fun readCursor(userId: String?, sessionId: String): String? =
        cursors[key(userId, sessionId)]

    override fun writeCursor(userId: String?, sessionId: String, cursor: String?) {
        val key = key(userId, sessionId) ?: return
        if (cursor.isNullOrBlank()) cursors.remove(key) else cursors[key] = cursor
    }

    override fun readOlderPage(userId: String?, sessionId: String): ChatOlderPage? =
        olderPages[key(userId, sessionId)]

    override fun writeOlderPage(userId: String?, sessionId: String, page: ChatOlderPage?) {
        val key = key(userId, sessionId) ?: return
        if (page == null) olderPages.remove(key) else olderPages[key] = page
    }

    override fun clear() {
        cleared = true
        rows.clear()
        cursors.clear()
        olderPages.clear()
    }

    private fun key(userId: String?, sessionId: String): String? {
        val user = userId?.takeIf { it.isNotBlank() } ?: return null
        if (sessionId.isBlank()) return null
        return "$user::$sessionId"
    }
}

class InMemoryRecentsCache : RecentsCache {
    private val workspaces = mutableMapOf<String, List<WorkspaceOption>>()
    private val chats = mutableMapOf<String, List<ChatSummary>>()

    var cleared = false
        private set

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? =
        workspaces[userKey(userId)]

    override fun writeWorkspaces(userId: String?, value: List<WorkspaceOption>) {
        workspaces[userKey(userId) ?: return] = value
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? =
        chats[chatsKey(userId, workspaceId)]

    override fun writeChats(userId: String?, workspaceId: String, value: List<ChatSummary>) {
        chats[chatsKey(userId, workspaceId) ?: return] = value
    }

    override fun clear() {
        cleared = true
        workspaces.clear()
        chats.clear()
    }

    private fun userKey(userId: String?): String? = userId?.takeIf { it.isNotBlank() }

    private fun chatsKey(userId: String?, workspaceId: String): String? {
        val user = userKey(userId) ?: return null
        if (workspaceId.isBlank()) return null
        return "$user::$workspaceId"
    }
}

/** The projects cache, in memory. */
class InMemoryProjectsCache : ProjectsCache {
    private val projects = mutableMapOf<String, List<ProjectSummary>>()
    private val chats = mutableMapOf<String, List<ProjectChat>>()

    var cleared = false
        private set

    override fun readProjects(
        userId: String?,
        workspaceId: String,
    ): List<ProjectSummary>? = projects[projectsKey(userId, workspaceId)]

    override fun writeProjects(
        userId: String?,
        workspaceId: String,
        value: List<ProjectSummary>,
    ) {
        projects[projectsKey(userId, workspaceId) ?: return] = value
    }

    override fun readProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
    ): List<ProjectChat>? = chats[chatsKey(userId, workspaceId, projectId)]

    override fun writeProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
        value: List<ProjectChat>,
    ) {
        chats[chatsKey(userId, workspaceId, projectId) ?: return] = value
    }

    override fun clear() {
        cleared = true
        projects.clear()
        chats.clear()
    }

    private fun projectsKey(userId: String?, workspaceId: String): String? {
        val user = userId?.takeIf { it.isNotBlank() } ?: return null
        if (workspaceId.isBlank()) return null
        return "$user::$workspaceId"
    }

    private fun chatsKey(userId: String?, workspaceId: String, projectId: String): String? {
        val base = projectsKey(userId, workspaceId) ?: return null
        if (projectId.isBlank()) return null
        return "$base::$projectId"
    }
}

/** The last-position store, in memory. */
class InMemoryLastPositionStore(
    seedUserId: String? = null,
    initial: LastPosition = LastPosition(),
) : LastPositionStore {
    private val positions = mutableMapOf<String, LastPosition>()

    /** Every write, in order, so a test can assert *what* moved and to where. */
    val writes = mutableListOf<LastPosition>()

    var cleared = false
        private set

    init {
        if (!initial.isEmpty) positions[scope(seedUserId)] = initial
    }

    override fun read(userId: String?): LastPosition = positions[scope(userId)] ?: LastPosition()

    override fun save(userId: String?, position: LastPosition) {
        val current = read(userId)
        val merged = LastPosition(
            workspaceId = position.workspaceId ?: current.workspaceId,
            sessionId = position.sessionId ?: current.sessionId,
        )
        positions[scope(userId)] = merged
        writes += merged
    }

    override fun saveWorkspace(userId: String?, workspaceId: String) {
        if (workspaceId.isBlank()) return
        val position = LastPosition(workspaceId = workspaceId)
        positions[scope(userId)] = position
        writes += position
    }

    override fun clear() {
        cleared = true
        positions.clear()
    }

    private fun scope(userId: String?): String = userId?.takeIf { it.isNotBlank() } ?: UNSCOPED

    private companion object {
        const val UNSCOPED = "unscoped"
    }
}

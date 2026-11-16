package com.pabrik.mobile.projects

import android.content.Context
import com.pabrik.mobile.cache.CachedProjectChatEntity
import com.pabrik.mobile.cache.CachedProjectEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import com.pabrik.mobile.cache.ProjectsCacheDao
import com.pabrik.mobile.recents.orNull
import com.pabrik.mobile.storage.KeystoreSealingCipher
import com.pabrik.mobile.storage.SealingCipher

/** Last-known project data, so a cold boot or an offline launch paints real project rows instead of an empty section. */
interface ProjectsCache {
    /** A null or blank `userId` is a miss, never an unscoped read — see [com.pabrik.mobile.recents.RecentsCache.readWorkspaces] for why the desktop's looser fallback … */
    fun readProjects(userId: String?, workspaceId: String): List<ProjectSummary>?

    fun writeProjects(userId: String?, workspaceId: String, projects: List<ProjectSummary>)

    fun readProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
    ): List<ProjectChat>?

    fun writeProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
        chats: List<ProjectChat>,
    )

    /** Drops every cached entry for every user. Called on sign-out. */
    fun clear()
}

/** [ProjectsCache] on Room, one row per project and per project chat, sealed with a Keystore key wherever the content is user text. */
class RoomProjectsCache(
    private val dao: ProjectsCacheDao,
    private val cipher: SealingCipher,
) : ProjectsCache {

    constructor(context: Context) : this(
        dao = PabrikCacheDatabase.get(context).projectsCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun readProjects(
        userId: String?,
        workspaceId: String,
    ): List<ProjectSummary>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.projectsFor(user, workspace)
            when {
                // A row store cannot tell "never fetched" from "this workspace has no projects", and `HomeViewModel` cannot either: it treats both as "nothing to paint, go and …
                rows.isEmpty() -> null

                // One unopenable row invalidates the whole list.
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteProjectsFor(user, workspace)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ProjectSummary(
                                id = row.projectId,
                                workspaceId = row.workspaceId,
                                itemType = row.itemType,
                                name = names[index].orEmpty(),
                                // The path is not stored.
                                path = "",
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeProjects(
        userId: String?,
        workspaceId: String,
        projects: List<ProjectSummary>,
    ) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val rows = quietly(null) { projects.toEntities(user, workspace) } ?: return
        // This deletes the chats of projects that have just disappeared, in the same transaction — see ProjectsCacheDao.deleteChatsForWorkspace.
        quietly(Unit) { dao.deleteChatsForWorkspace(user, workspace, rows) }
    }

    override fun readProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
    ): List<ProjectChat>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        val project = projectId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.projectChatsFor(user, workspace, project)
            when {
                rows.isEmpty() -> null
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteProjectChatsFor(user, workspace, project)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ProjectChat(
                                id = row.chatId,
                                projectId = row.projectId,
                                name = names[index].orEmpty(),
                                updatedAtEpochMillis = row.updatedAtEpochMillis,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeProjectChats(
        userId: String?,
        workspaceId: String,
        projectId: String,
        chats: List<ProjectChat>,
    ) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val project = projectId.orNull() ?: return
        val rows = quietly(null) { chats.toEntities(user, workspace, project) } ?: return
        quietly(Unit) { dao.replaceProjectChats(user, workspace, project, rows) }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /** Sealing, all-or-nothing. */
    private fun List<ProjectSummary>.toEntities(
        userId: String,
        workspaceId: String,
    ): List<CachedProjectEntity>? {
        val out = ArrayList<CachedProjectEntity>(size)
        forEachIndexed { index, project ->
            val sealed = cipher.seal(project.name) ?: return null
            out.add(
                CachedProjectEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    projectId = project.id,
                    position = index,
                    itemType = project.itemType,
                    nameSealed = sealed,
                ),
            )
        }
        return out
    }

    private fun List<ProjectChat>.toEntities(
        userId: String,
        workspaceId: String,
        projectId: String,
    ): List<CachedProjectChatEntity>? {
        val out = ArrayList<CachedProjectChatEntity>(size)
        forEachIndexed { index, chat ->
            val sealed = cipher.seal(chat.name) ?: return null
            out.add(
                CachedProjectChatEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    projectId = projectId,
                    chatId = chat.id,
                    position = index,
                    updatedAtEpochMillis = chat.updatedAtEpochMillis,
                    nameSealed = sealed,
                ),
            )
        }
        return out
    }

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        /** Its own alias, distinct from the recents cache's and the session cookie's. */
        const val KEY_ALIAS = "pabrik_projects_cache_key_v1"
    }
}

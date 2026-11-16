package com.pabrik.mobile.recents

import android.content.Context
import com.pabrik.mobile.cache.CachedChatSummaryEntity
import com.pabrik.mobile.cache.CachedWorkspaceEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import com.pabrik.mobile.cache.RecentsCacheDao
import com.pabrik.mobile.storage.KeystoreSealingCipher
import com.pabrik.mobile.storage.SealingCipher

/** Last-known sidebar data, so a cold boot or an offline launch paints real rows instead of an error screen. */
interface RecentsCache {
    /** A null or blank `userId` is a miss, never an unscoped read. */
    fun readWorkspaces(userId: String?): List<WorkspaceOption>?

    fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>)

    fun readChats(userId: String?, workspaceId: String): List<ChatSummary>?

    fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>)

    /** Drops every cached entry for every user. Called on sign-out. */
    fun clear()
}

/** [RecentsCache] on Room, one row per workspace and per chat, sealed with a Keystore key wherever the content is user text. */
class RoomRecentsCache(
    private val dao: RecentsCacheDao,
    private val cipher: SealingCipher,
) : RecentsCache {

    constructor(context: Context) : this(
        dao = PabrikCacheDatabase.get(context).recentsCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun readWorkspaces(userId: String?): List<WorkspaceOption>? {
        val user = userId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.workspacesFor(user)
            when {
                // Nothing cached.
                rows.isEmpty() -> null

                // One unopenable row invalidates the whole list, exactly as one undecryptable preference did before.
                else -> {
                    val names = rows.map { cipher.open(it.nameSealed) }
                    if (names.any { it == null }) {
                        dao.deleteWorkspacesFor(user)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            WorkspaceOption(id = row.workspaceId, name = names[index].orEmpty())
                        }
                    }
                }
            }
        }
    }

    override fun writeWorkspaces(userId: String?, workspaces: List<WorkspaceOption>) {
        val user = userId.orNull() ?: return
        val rows = quietly(null) { workspaces.toEntities(user) } ?: return
        quietly(Unit) { dao.replaceWorkspaces(user, rows) }
    }

    override fun readChats(userId: String?, workspaceId: String): List<ChatSummary>? {
        val user = userId.orNull() ?: return null
        val workspace = workspaceId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.chatsFor(user, workspace)
            when {
                rows.isEmpty() -> null

                else -> {
                    val titles = rows.map { cipher.open(it.titleSealed) }
                    if (titles.any { it == null }) {
                        dao.deleteChatsFor(user, workspace)
                        null
                    } else {
                        rows.mapIndexed { index, row ->
                            ChatSummary(
                                id = row.chatId,
                                workspaceId = row.workspaceId,
                                title = titles[index].orEmpty(),
                                updatedAtEpochMillis = row.updatedAtEpochMillis,
                                lastHumanTouchedAtEpochMillis = row.lastHumanTouchedAtEpochMillis,
                            )
                        }
                    }
                }
            }
        }
    }

    override fun writeChats(userId: String?, workspaceId: String, chats: List<ChatSummary>) {
        val user = userId.orNull() ?: return
        val workspace = workspaceId.orNull() ?: return
        val rows = quietly(null) { chats.toEntities(user, workspace) } ?: return
        quietly(Unit) { dao.replaceChats(user, workspace, rows) }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /** Sealing, all-or-nothing. */
    private fun List<WorkspaceOption>.toEntities(userId: String): List<CachedWorkspaceEntity>? {
        val out = ArrayList<CachedWorkspaceEntity>(size)
        forEachIndexed { index, workspace ->
            val sealed = cipher.seal(workspace.name) ?: return null
            out.add(
                CachedWorkspaceEntity(
                    userId = userId,
                    workspaceId = workspace.id,
                    position = index,
                    nameSealed = sealed,
                ),
            )
        }
        return out
    }

    private fun List<ChatSummary>.toEntities(
        userId: String,
        workspaceId: String,
    ): List<CachedChatSummaryEntity>? {
        val out = ArrayList<CachedChatSummaryEntity>(size)
        forEachIndexed { index, chat ->
            val sealed = cipher.seal(chat.title) ?: return null
            out.add(
                CachedChatSummaryEntity(
                    userId = userId,
                    workspaceId = workspaceId,
                    chatId = chat.id,
                    position = index,
                    updatedAtEpochMillis = chat.updatedAtEpochMillis,
                    lastHumanTouchedAtEpochMillis = chat.lastHumanTouchedAtEpochMillis,
                    titleSealed = sealed,
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
        /** Distinct from the session cookie's and the `/me` cache's aliases */
        const val KEY_ALIAS = "pabrik_cache_key_v1"
    }
}

/** A null or blank identity cannot address a partition, so it is not a partition. */
internal fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }

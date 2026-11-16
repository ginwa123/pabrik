package com.pabrik.mobile.chat

import android.content.Context
import com.pabrik.mobile.cache.CachedMessageEntity
import com.pabrik.mobile.cache.ChatCacheDao
import com.pabrik.mobile.cache.ChatCursorEntity
import com.pabrik.mobile.cache.ChatOlderPageEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import org.json.JSONObject

/** One cached transcript row. */
data class CachedChatMessage(
    val id: String,
    val sortKeyNanos: Long,
    val sessionId: String,
    val role: String,
    val content: String,
    val raw: String,
)

/** Where a session's older history starts, and whether the server said there is more above it. */
data class ChatOlderPage(
    val cursor: String,
    val hasMore: Boolean,
)

/** Last-known transcript, so a cold boot or an offline launch paints real messages instead of a spinner. */
interface ChatCache {
    /** Newest first, capped at [limit] — the IndexedDB `getAll` contract. */
    fun readMessages(userId: String?, sessionId: String, limit: Int): List<CachedChatMessage>?

    /** Write-through merge: a same-id row replaces the cached one. */
    fun writeMessages(userId: String?, sessionId: String, messages: List<CachedChatMessage>)

    fun readCursor(userId: String?, sessionId: String): String?

    fun writeCursor(userId: String?, sessionId: String, cursor: String?)

    /** The session's older boundary, or null when this device has never fetched a descending page for it. */
    fun readOlderPage(userId: String?, sessionId: String): ChatOlderPage?

    /** A null [page] drops the boundary — the server said there is nothing older. */
    fun writeOlderPage(userId: String?, sessionId: String, page: ChatOlderPage?)

    /** Drops every cached transcript and cursor, for every user. */
    fun clear()
}

/** The pure half of the cache — building a row from a wire object and the monotonic cursor rule — with no Android dependency so it can be exercised on the JVM. */
object ChatCacheCodec {

    /** Builds a cache row from a wire object, hoisting the two fields the cache indexes on. */
    fun toCachedMessage(sessionId: String, row: JSONObject): CachedChatMessage? {
        val id = row.optNullableString("id")?.trim().orEmpty()
        if (id.isEmpty()) return null
        return CachedChatMessage(
            id = id,
            sortKeyNanos = ChatApi.parseCreatedAtNanos(row.optNullableString("created_at")),
            sessionId = sessionId,
            role = row.optNullableString("role").orEmpty(),
            content = row.optNullableString("content").orEmpty(),
            raw = row.toString(),
        )
    }

    /** Sync cursor for the next tail fetch: the newest row seen so far. */
    fun newestCursor(
        items: List<CachedChatMessage>,
        nextCursor: String?,
        previousCursor: String?,
    ): String? {
        var best: Long? = previousCursor?.trim()?.toLongOrNull()
        items.forEach { item ->
            if (item.sortKeyNanos > 0L && (best == null || item.sortKeyNanos > best!!)) {
                best = item.sortKeyNanos
            }
        }
        return best?.toString() ?: nextCursor ?: previousCursor
    }
}

/** [ChatCache] on Room, one row per message. */
class RoomChatCache(
    private val dao: ChatCacheDao,
    private val retainedRowsPerSession: Int = RETAINED_ROWS_PER_SESSION,
) : ChatCache {

    constructor(context: Context) : this(PabrikCacheDatabase.get(context).chatCacheDao())

    override fun readMessages(
        userId: String?,
        sessionId: String,
        limit: Int,
    ): List<CachedChatMessage>? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) {
            val rows = dao.newestFirst(
                userId = user,
                sessionId = session,
                limit = limit.coerceAtLeast(1),
            )
            // No rows is a miss, and it is the *only* miss a read can have now.
            if (rows.isEmpty()) null else rows.map { it.toCachedMessage() }
        }
    }

    override fun writeMessages(
        userId: String?,
        sessionId: String,
        messages: List<CachedChatMessage>,
    ) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        // An empty write is a no-op rather than a purge.
        if (messages.isEmpty()) return
        quietly(Unit) {
            dao.writeThrough(
                userId = user,
                sessionId = session,
                rows = messages.map { it.toEntity(user, session) },
                keep = retainedRowsPerSession,
            )
        }
    }

    override fun readCursor(userId: String?, sessionId: String): String? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) { dao.cursorFor(user, session) }
    }

    override fun writeCursor(userId: String?, sessionId: String, cursor: String?) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        quietly(Unit) {
            if (cursor.isNullOrBlank()) {
                dao.deleteCursor(user, session)
            } else {
                dao.putCursor(ChatCursorEntity(userId = user, sessionId = session, cursor = cursor))
            }
        }
    }

    override fun readOlderPage(userId: String?, sessionId: String): ChatOlderPage? {
        val user = userId.orNull() ?: return null
        val session = sessionId.orNull() ?: return null
        return quietly(null) {
            dao.olderPageFor(user, session)?.let { row ->
                ChatOlderPage(cursor = row.cursor, hasMore = row.hasMore)
            }
        }
    }

    override fun writeOlderPage(userId: String?, sessionId: String, page: ChatOlderPage?) {
        val user = userId.orNull() ?: return
        val session = sessionId.orNull() ?: return
        quietly(Unit) {
            if (page == null) {
                dao.deleteOlderPage(user, session)
            } else {
                dao.putOlderPage(
                    ChatOlderPageEntity(
                        userId = user,
                        sessionId = session,
                        cursor = page.cursor,
                        hasMore = page.hasMore,
                    ),
                )
            }
        }
    }

    override fun clear() = quietly(Unit) { dao.clearAll() }

    /** Runs a cache operation and reports a miss instead of throwing. */
    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    companion object {
        /** How many rows one session may keep on the device. */
        const val RETAINED_ROWS_PER_SESSION = 2_000
    }
}

/** A null or blank identity cannot address a partition, so it is not a partition. */
private fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }

private fun CachedMessageEntity.toCachedMessage(): CachedChatMessage = CachedChatMessage(
    id = messageId,
    sortKeyNanos = sortKeyNanos,
    sessionId = sessionId,
    role = role,
    content = content,
    raw = raw,
)

/** Both partition columns come from the *call*, not from the row. */
private fun CachedChatMessage.toEntity(
    userId: String,
    sessionId: String,
): CachedMessageEntity = CachedMessageEntity(
    userId = userId,
    sessionId = sessionId,
    messageId = id,
    sortKeyNanos = sortKeyNanos,
    role = role,
    content = content,
    raw = raw,
)

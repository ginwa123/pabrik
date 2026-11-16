package com.pabrik.mobile.cache

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

/** One cached transcript row, and one table per cache partition. */

/** A transcript row. */
@Entity(
    tableName = "cached_messages",
    primaryKeys = ["user_id", "session_id", "message_id"],
    // Covers `WHERE user_id AND session_id ORDER BY sort_key_nanos DESC, message_id DESC` — every transcript read this app makes.
    indices = [
        Index(value = ["user_id", "session_id", "sort_key_nanos", "message_id"]),
    ],
)
data class CachedMessageEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "session_id") val sessionId: String,
    @ColumnInfo(name = "message_id") val messageId: String,
    @ColumnInfo(name = "sort_key_nanos") val sortKeyNanos: Long,
    val role: String,
    val content: String,
    /** Deliberately NOT sealed. */
    val raw: String,
)

/** The monotonic tail-fetch cursor for one session. */
@Entity(
    tableName = "chat_cursors",
    primaryKeys = ["user_id", "session_id"],
)
data class ChatCursorEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "session_id") val sessionId: String,
    val cursor: String,
)

/** Where one session's *older* history starts, and whether the server said there is any above it. */
@Entity(
    tableName = "chat_older_pages",
    primaryKeys = ["user_id", "session_id"],
)
data class ChatOlderPageEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "session_id") val sessionId: String,
    /** The server's own `next_cursor` for a *descending* page: the `created_at_nano` of the oldest row of the page that was last fetched. */
    val cursor: String,
    /** Whether the server said there is more above [cursor]. */
    @ColumnInfo(name = "has_more") val hasMore: Boolean,
)

/** One workspace row, in the order the server sent it. */
@Entity(
    tableName = "cached_workspaces",
    primaryKeys = ["user_id", "workspace_id"],
    indices = [Index(value = ["user_id", "position"])],
)
data class CachedWorkspaceEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    val position: Int,
    /** Sealed: a workspace name is user content on a device that may be shared. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)

/** One recent-chat row, in the order the server sent it. */
@Entity(
    tableName = "cached_chat_summaries",
    primaryKeys = ["user_id", "workspace_id", "chat_id"],
    indices = [Index(value = ["user_id", "workspace_id", "position"])],
)
data class CachedChatSummaryEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "chat_id") val chatId: String,
    val position: Int,
    @ColumnInfo(name = "updated_at_epoch_millis") val updatedAtEpochMillis: Long,
    @ColumnInfo(name = "last_human_touched_at_epoch_millis")
    val lastHumanTouchedAtEpochMillis: Long,
    /** Sealed: a chat title is the single most identifying string in the app. */
    @ColumnInfo(name = "title_sealed") val titleSealed: String,
)

/** One cached `GET /api/auth/me` response, keyed by a fingerprint of the session cookie. */
@Entity(tableName = "cached_auth_me", primaryKeys = ["cookie_fingerprint"])
data class CachedAuthMeEntity(
    @ColumnInfo(name = "cookie_fingerprint") val cookieFingerprint: String,
    @ColumnInfo(name = "body_sealed") val bodySealed: String,
    @ColumnInfo(name = "stored_at_epoch_millis") val storedAtEpochMillis: Long,
)

/** One `workspace_items` row, in the order the server sent it. */
@Entity(
    tableName = "cached_projects",
    primaryKeys = ["user_id", "workspace_id", "project_id"],
    indices = [Index(value = ["user_id", "workspace_id", "position"])],
)
data class CachedProjectEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "project_id") val projectId: String,
    val position: Int,
    /** NOT sealed, unlike the name beside it. */
    val itemType: String,
    /** Sealed: a project name is user content on a device that may be shared. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)

/** One project's chat row, in the order the server sent it. */
@Entity(
    tableName = "cached_project_chats",
    primaryKeys = ["user_id", "workspace_id", "project_id", "chat_id"],
    indices = [Index(value = ["user_id", "workspace_id", "project_id", "position"])],
)
data class CachedProjectChatEntity(
    @ColumnInfo(name = "user_id") val userId: String,
    @ColumnInfo(name = "workspace_id") val workspaceId: String,
    @ColumnInfo(name = "project_id") val projectId: String,
    @ColumnInfo(name = "chat_id") val chatId: String,
    val position: Int,
    /** In the clear for the same reason a recents row's is: it is the sort key, and sealing it would mean decrypting every row to order them. */
    @ColumnInfo(name = "updated_at_epoch_millis") val updatedAtEpochMillis: Long,
    /** Sealed: a chat title is the single most identifying string in the app. */
    @ColumnInfo(name = "name_sealed") val nameSealed: String,
)

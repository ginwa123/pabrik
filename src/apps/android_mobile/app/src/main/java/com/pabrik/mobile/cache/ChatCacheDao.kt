package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/** The transcript cache's SQL. */
@Dao
abstract class ChatCacheDao {

    /** Newest first, capped at [limit] — the IndexedDB `getAll` contract the web's `ChatEngineDb` uses. */
    @Query(
        """
        SELECT * FROM cached_messages
        WHERE user_id = :userId AND session_id = :sessionId
        ORDER BY sort_key_nanos DESC, message_id DESC
        LIMIT :limit
        """,
    )
    abstract fun newestFirst(
        userId: String,
        sessionId: String,
        limit: Int,
    ): List<CachedMessageEntity>

    /** Write-through merge: a same-id row replaces the cached one. */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsert(rows: List<CachedMessageEntity>)

    @Query("SELECT cursor FROM chat_cursors WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun cursorFor(userId: String, sessionId: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun putCursor(row: ChatCursorEntity)

    @Query("DELETE FROM chat_cursors WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun deleteCursor(userId: String, sessionId: String)

    /** The session's older boundary, or null when none has been established. */
    @Query(
        "SELECT * FROM chat_older_pages WHERE user_id = :userId AND session_id = :sessionId",
    )
    abstract fun olderPageFor(userId: String, sessionId: String): ChatOlderPageEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun putOlderPage(row: ChatOlderPageEntity)

    @Query("DELETE FROM chat_older_pages WHERE user_id = :userId AND session_id = :sessionId")
    abstract fun deleteOlderPage(userId: String, sessionId: String)

    /** Drops everything past the newest [keep] rows of one session. */
    @Query(
        """
        DELETE FROM cached_messages
        WHERE user_id = :userId AND session_id = :sessionId
          AND message_id NOT IN (
            SELECT message_id FROM cached_messages
            WHERE user_id = :userId AND session_id = :sessionId
            ORDER BY sort_key_nanos DESC, message_id DESC
            LIMIT :keep
          )
        """,
    )
    abstract fun trimToNewest(
        userId: String,
        sessionId: String,
        keep: Int,
    )

    /** Insert and trim as one transaction. */
    @Transaction
    open fun writeThrough(
        userId: String,
        sessionId: String,
        rows: List<CachedMessageEntity>,
        keep: Int,
    ) {
        upsert(rows)
        trimToNewest(userId, sessionId, keep)
    }

    @Query("DELETE FROM cached_messages")
    abstract fun deleteAllMessages()

    @Query("DELETE FROM chat_cursors")
    abstract fun deleteAllCursors()

    @Query("DELETE FROM chat_older_pages")
    abstract fun deleteAllOlderPages()

    /** Sign-out purge, in one transaction. */
    @Transaction
    open fun clearAll() {
        deleteAllMessages()
        deleteAllCursors()
        deleteAllOlderPages()
    }
}

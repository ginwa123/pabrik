package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/** The sidebar cache's SQL: workspaces and recent chats, both partitioned by user *and* by workspace. */
@Dao
abstract class RecentsCacheDao {

    /** Server order, not sorted order. */
    @Query(
        """
        SELECT * FROM cached_workspaces
        WHERE user_id = :userId
        ORDER BY position ASC
        """,
    )
    abstract fun workspacesFor(userId: String): List<CachedWorkspaceEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertWorkspaces(rows: List<CachedWorkspaceEntity>)

    @Query("DELETE FROM cached_workspaces WHERE user_id = :userId")
    abstract fun deleteWorkspacesFor(userId: String)

    @Query(
        """
        SELECT * FROM cached_chat_summaries
        WHERE user_id = :userId AND workspace_id = :workspaceId
        ORDER BY position ASC
        """,
    )
    abstract fun chatsFor(
        userId: String,
        workspaceId: String,
    ): List<CachedChatSummaryEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertChats(rows: List<CachedChatSummaryEntity>)

    @Query(
        "DELETE FROM cached_chat_summaries WHERE user_id = :userId AND workspace_id = :workspaceId",
    )
    abstract fun deleteChatsFor(userId: String, workspaceId: String)

    /** Replace-not-merge, for both lists. */
    @Transaction
    open fun replaceWorkspaces(userId: String, rows: List<CachedWorkspaceEntity>) {
        deleteWorkspacesFor(userId)
        if (rows.isNotEmpty()) upsertWorkspaces(rows)
    }

    @Transaction
    open fun replaceChats(
        userId: String,
        workspaceId: String,
        rows: List<CachedChatSummaryEntity>,
    ) {
        deleteChatsFor(userId, workspaceId)
        if (rows.isNotEmpty()) upsertChats(rows)
    }

    @Query("DELETE FROM cached_workspaces")
    abstract fun deleteAllWorkspaces()

    @Query("DELETE FROM cached_chat_summaries")
    abstract fun deleteAllChats()

    /** Sign-out purge, in one transaction. See [ChatCacheDao.clearAll]. */
    @Transaction
    open fun clearAll() {
        deleteAllWorkspaces()
        deleteAllChats()
    }
}

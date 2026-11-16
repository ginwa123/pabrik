package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction

/** The projects cache's SQL: a workspace's projects, and each project's chats. */
@Dao
abstract class ProjectsCacheDao {

    @Query(
        """
        SELECT * FROM cached_projects
        WHERE user_id = :userId AND workspace_id = :workspaceId
        ORDER BY position ASC
        """,
    )
    abstract fun projectsFor(
        userId: String,
        workspaceId: String,
    ): List<CachedProjectEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertProjects(rows: List<CachedProjectEntity>)

    @Query("DELETE FROM cached_projects WHERE user_id = :userId AND workspace_id = :workspaceId")
    abstract fun deleteProjectsFor(
        userId: String,
        workspaceId: String,
    )

    @Query(
        """
        SELECT * FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId AND project_id = :projectId
        ORDER BY position ASC
        """,
    )
    abstract fun projectChatsFor(
        userId: String,
        workspaceId: String,
        projectId: String,
    ): List<CachedProjectChatEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    abstract fun upsertProjectChats(rows: List<CachedProjectChatEntity>)

    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId AND project_id = :projectId
        """,
    )
    abstract fun deleteProjectChatsFor(
        userId: String,
        workspaceId: String,
        projectId: String,
    )

    /** Replace-not-merge, for both lists, in one transaction each. */
    @Transaction
    open fun replaceProjects(
        userId: String,
        workspaceId: String,
        rows: List<CachedProjectEntity>,
    ) {
        deleteProjectsFor(userId, workspaceId)
        if (rows.isNotEmpty()) upsertProjects(rows)
    }

    @Transaction
    open fun replaceProjectChats(
        userId: String,
        workspaceId: String,
        projectId: String,
        rows: List<CachedProjectChatEntity>,
    ) {
        deleteProjectChatsFor(userId, workspaceId, projectId)
        if (rows.isNotEmpty()) upsertProjectChats(rows)
    }

    /** Drop a workspace's chats when the workspace's projects are replaced. */
    @Transaction
    open fun deleteChatsForWorkspace(
        userId: String,
        workspaceId: String,
        rows: List<CachedProjectEntity>,
    ) {
        if (rows.isEmpty()) {
            deleteAllProjectChatsFor(userId, workspaceId)
        } else {
            deleteProjectChatsForMissing(userId, workspaceId, rows.map { it.projectId })
        }
        replaceProjects(userId, workspaceId, rows)
    }

    /** Every chat in this workspace, for the "this workspace has no projects" case. */
    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId AND workspace_id = :workspaceId
        """,
    )
    abstract fun deleteAllProjectChatsFor(
        userId: String,
        workspaceId: String,
    )

    /** Delete the chats of every project not in [keepProjectIds]. */
    @Query(
        """
        DELETE FROM cached_project_chats
        WHERE user_id = :userId
          AND workspace_id = :workspaceId
          AND project_id NOT IN (:keepProjectIds)
        """,
    )
    abstract fun deleteProjectChatsForMissing(
        userId: String,
        workspaceId: String,
        keepProjectIds: List<String>,
    )

    @Query("DELETE FROM cached_projects")
    abstract fun deleteAllProjects()

    @Query("DELETE FROM cached_project_chats")
    abstract fun deleteAllProjectChats()

    /** Sign-out purge, in one transaction. */
    @Transaction
    open fun clearAll() {
        deleteAllProjects()
        deleteAllProjectChats()
    }
}

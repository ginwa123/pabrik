package com.pabrik.mobile.cache

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/** One SQLite file for all three offline caches. */
@Database(
    entities = [
        CachedMessageEntity::class,
        ChatCursorEntity::class,
        ChatOlderPageEntity::class,
        CachedWorkspaceEntity::class,
        CachedChatSummaryEntity::class,
        CachedAuthMeEntity::class,
        CachedProjectEntity::class,
        CachedProjectChatEntity::class,
        OutboxEntry::class,
    ],
    // 2 adds the two projects tables.
    version = 3,
    exportSchema = false,
)
abstract class PabrikCacheDatabase : RoomDatabase() {

    abstract fun chatCacheDao(): ChatCacheDao

    abstract fun recentsCacheDao(): RecentsCacheDao

    abstract fun authMeCacheDao(): AuthMeCacheDao

    abstract fun projectsCacheDao(): ProjectsCacheDao

    abstract fun outboxDao(): OutboxDao

    companion object {
        const val NAME = "pabrik_cache.db"

        @Volatile
        private var instance: PabrikCacheDatabase? = null

        /** The process-wide instance the three caches share. */
        fun get(context: Context): PabrikCacheDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(context: Context): PabrikCacheDatabase =
            Room.databaseBuilder(context, PabrikCacheDatabase::class.java, NAME)
                .allowMainThreadQueries()
                // A cache is the one database class where a destructive migration is the right answer.
                .fallbackToDestructiveMigration()
                .build()
    }
}

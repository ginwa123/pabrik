package com.pabrik.mobile.cache

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

/**
 * One SQLite file for all three offline caches.
 *
 * One database rather than three, because the three share a lifecycle: they are
 * written by the same three ViewModels, purged by the same sign-out, and are
 * all rebuildable from the network. Splitting them would triple the
 * connection pool, the WAL files, and the places a sign-out has to remember to
 * reach, for no isolation that a table name does not already give.
 *
 * ### `allowMainThreadQueries` is deliberate
 *
 * Room's default — throw if a query touches the main thread — exists because a
 * query that is "one row" in the schema can be "the whole table" at runtime.
 * Every read this database serves is the opposite: each one is a point lookup
 * on the primary-key prefix with a `LIMIT`, or a full delete for a table that
 * holds at most a few hundred short rows. The queries are in
 * [ChatCacheDao], [RecentsCacheDao] and [AuthMeCacheDao], and the reader can
 * check that claim in one sitting.
 *
 * More to the point, the call site is not new. `HomeViewModel` primes the
 * sidebar from cache on the main thread, and the store it used to prime from
 * was `EncryptedPrefs`, which does a Keystore AES-GCM decrypt of a blob on that
 * same main thread. A `LIMIT`ed index-backed point query is not merely
 * acceptable there, it is *cheaper* than what it replaced. Changing the reads
 * to suspend would be the honest fix, but it would put a coroutine hop between
 * the launch and the paint, and the tests that hold the ordering contract
 * (`HomeViewModelCacheTest.aCachedSidebarPaintsBeforeTheNetworkReturns`) would
 * be describing a first frame that no longer exists.
 *
 * Writes are the other way round: every caller wraps them in
 * `Dispatchers.IO` before reaching a cache, so they run off the main thread
 * anyway.
 */
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
    // 2 adds the two projects tables. Bumped because the schema changed, not
    // because the data is worth migrating: `fallbackToDestructiveMigration` below
    // is the right answer for a cache (everything here is a copy of something
    // the server still holds, and every paint is followed by a live fetch), so
    // the cost of the bump is one empty sidebar and one spinner on the first
    // launch after the upgrade. Leaving it at 1 would fail Room's identity
    // check outright and crash on open.
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

        /**
         * The process-wide instance the three caches share.
         *
         * `Room.databaseBuilder` is itself idempotent — it returns the same
         * builder for the same name — so the `instance` guard is only here to
         * avoid re-entering the builder on a path the caches call during
         * startup, and to make the "one connection for all three" promise
         * visible at the call site instead of being an emergent property.
         */
        fun get(context: Context): PabrikCacheDatabase =
            instance ?: synchronized(this) {
                instance ?: build(context.applicationContext).also { instance = it }
            }

        private fun build(context: Context): PabrikCacheDatabase =
            Room.databaseBuilder(context, PabrikCacheDatabase::class.java, NAME)
                .allowMainThreadQueries()
                // A cache is the one database class where a destructive
                // migration is the right answer. Everything in here is a copy of
                // something the server still holds, every paint is immediately
                // followed by a live fetch, and the alternative — carrying a
                // migration for a table whose only consumer throws the contents
                // away on a schema bump — is a class of bug with no upside. The
                // cost is one empty sidebar and one spinner on the first launch
                // after an upgrade.
                .fallbackToDestructiveMigration()
                .build()
    }
}

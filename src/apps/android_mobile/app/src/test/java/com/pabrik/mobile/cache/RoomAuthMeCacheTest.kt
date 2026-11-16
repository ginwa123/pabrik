package com.pabrik.mobile.cache

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.pabrik.mobile.auth.AuthMeCacheCodec
import com.pabrik.mobile.auth.RoomAuthMeCache
import com.pabrik.mobile.storage.SealingCipher
import com.pabrik.mobile.testing.Base64CacheCipher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The `/me` cache against a **real** SQLite database. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class RoomAuthMeCacheTest {

    private lateinit var database: PabrikCacheDatabase
    private lateinit var cache: RoomAuthMeCache

    @Before
    fun setUp() {
        database = Room.inMemoryDatabaseBuilder(
            ApplicationProvider.getApplicationContext(),
            PabrikCacheDatabase::class.java,
        ).allowMainThreadQueries().build()
        cache = RoomAuthMeCache(database.authMeCacheDao(), Base64CacheCipher)
    }

    @After
    fun tearDown() {
        database.close()
    }

    private fun fingerprintOf(cookie: String) = AuthMeCacheCodec.fingerprint(cookie)!!

    // --- Namespacing --------------------------------------------------------

    @Test
    fun oneCookieFingerprintCannotReachAnotherAccountsCachedIdentity() {
        val a = fingerprintOf("tok-a")
        val b = fingerprintOf("tok-b")
        cache.write(a, """{"user":{"id":"u_a"}}""", NOW)

        assertEquals("""{"user":{"id":"u_a"}}""", cache.read(a)?.body)
        // This is the whole point of the fingerprint.
        assertNull(cache.read(b))
    }

    @Test
    fun aBlankFingerprintIsAMissAndCannotBeWritten() {
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED, NOW)
        cache.write("", AUTHENTICATED, NOW)
        cache.write("   ", AUTHENTICATED, NOW)

        assertNull(cache.read(""))
        assertNull(cache.read("   "))
        // The two legitimate writes are the only rows that exist.
        assertEquals(1, countRows())
    }

    @Test
    fun aWriteReplacesTheEntryRatherThanAppendingASecond() {
        val fingerprint = fingerprintOf("tok-a")
        cache.write(fingerprint, AUTHENTICATED, NOW)
        cache.write(fingerprint, """{"user":{"id":"u_new"}}""", NOW + 1)

        assertEquals(1, countRows())
        assertEquals("""{"user":{"id":"u_new"}}""", cache.read(fingerprint)?.body)
    }

    // --- The stored fields --------------------------------------------------

    @Test
    fun theTimestampTheCallerSuppliedIsTheOneStored() {
        // Freshness is a policy decision the DAO must not make: `AuthClient` is the only thing that knows whether a retry is bypassing the cache on purpose.
        val fingerprint = fingerprintOf("tok-a")
        cache.write(fingerprint, AUTHENTICATED, 1_000L)

        assertEquals(1_000L, cache.read(fingerprint)?.storedAtEpochMillis)
    }

    @Test
    fun aFreshEntryIsStillFreshAfterARoundTripThroughTheDatabase() {
        val fingerprint = fingerprintOf("tok-a")
        val ttl = AuthMeCacheCodec.TTL_MILLIS
        cache.write(fingerprint, AUTHENTICATED, NOW)

        val entry = cache.read(fingerprint)!!
        assertEquals(true, entry.isFresh(NOW, ttl))
        assertEquals(false, entry.isFresh(NOW + ttl, ttl))
    }

    @Test
    fun theBodyIsNotSittingInTheDatabaseInTheClear() {
        val fingerprint = fingerprintOf("tok-a")
        cache.write(fingerprint, AUTHENTICATED, NOW)

        val column = database.openHelper.readableDatabase.query(
            "SELECT body_sealed FROM cached_auth_me WHERE cookie_fingerprint = ?",
            arrayOf(fingerprint),
        ).use { cursor ->
            cursor.moveToFirst()
            cursor.getString(0)
        }

        // Unlike the sidebar's table there is nothing to order or filter on here, so the whole body is sealed.
        assertFalse(column, column.contains("authenticated"))
        assertFalse(column, column.contains("u_1"))
    }

    @Test
    fun theCookieItselfIsNotInTheDatabase() {
        val cookie = "tok-super-secret-value"
        cache.write(fingerprintOf(cookie), AUTHENTICATED, NOW)

        // The fingerprint is the primary key and the body is sealed, so a dump of the file — which is what a shared-device extraction, a bug report or a backup produces …
        val dump = dumpTable("cached_auth_me")
        assertEquals(1, countRows())
        assertFalse(dump, dump.contains(cookie))
    }

    /** Every cell of a table, flattened — what a `sqlite3` dump of the file would hand to whoever opened the device next. */
    private fun dumpTable(table: String): String = database.openHelper.readableDatabase
        .query("SELECT * FROM $table")
        .use { cursor ->
            buildString {
                while (cursor.moveToNext()) {
                    for (column in 0 until cursor.columnCount) {
                        append(cursor.getString(column)).append('|')
                    }
                }
            }
        }

    // --- Fail-silent --------------------------------------------------------

    @Test
    fun anUnopenableBodyIsAMissAndTheRowIsDropped() {
        val fingerprint = fingerprintOf("tok-a")
        cache.write(fingerprint, AUTHENTICATED, NOW)
        database.openHelper.writableDatabase.execSQL(
            "UPDATE cached_auth_me SET body_sealed = ? WHERE cookie_fingerprint = ?",
            arrayOf<Any>("not-base64-at-all!!", fingerprint),
        )

        assertNull(cache.read(fingerprint))
        // Dropped, so the same failing decryption is not re-attempted on every launch — the same thing `EncryptedPrefs` did with the entry it could not read.
        assertEquals(0, countRows())
    }

    @Test
    fun aCipherThatCannotSealSkipsTheWrite() {
        val refusing = RoomAuthMeCache(
            database.authMeCacheDao(),
            object : SealingCipher {
                override fun seal(plainText: String): String? = null
                override fun open(sealed: String): String? = null
            },
        )

        refusing.write(fingerprintOf("tok-a"), AUTHENTICATED, NOW)

        // A Keystore that will not open must leave the app fetching from the network, not crash the launch and not store the body in the clear.
        assertEquals(0, countRows())
    }

    @Test
    fun aFirstReadOnAnEmptyDatabaseIsAMissNotAFailure() {
        assertNull(cache.read(fingerprintOf("tok-a")))
    }

    // --- Sign-out -----------------------------------------------------------

    @Test
    fun clearPurgesEveryFingerprint() {
        cache.write(fingerprintOf("tok-a"), AUTHENTICATED, NOW)
        cache.write(fingerprintOf("tok-b"), AUTHENTICATED, NOW)

        cache.clear()

        // Signing out makes the old entry unreachable anyway — there is no cookie to derive its key from — but leaving it on disk would keep an identity around after the …
        assertNull(cache.read(fingerprintOf("tok-a")))
        assertNull(cache.read(fingerprintOf("tok-b")))
        assertEquals(0, countRows())
    }

    private fun countRows(): Int = database.openHelper.readableDatabase
        .query("SELECT COUNT(*) FROM cached_auth_me")
        .use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    private companion object {
        const val NOW = 1_700_000_000_000L
        const val AUTHENTICATED =
            """{"authenticated":true,"auth_enabled":true,"user":{"id":"u_1"}}"""
    }
}

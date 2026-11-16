package com.pabrik.mobile.cache

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

/** The `GET /api/auth/me` cache: one row per session-cookie fingerprint. */
@Dao
interface AuthMeCacheDao {

    @Query("SELECT * FROM cached_auth_me WHERE cookie_fingerprint = :cookieFingerprint")
    fun find(cookieFingerprint: String): CachedAuthMeEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun put(row: CachedAuthMeEntity)

    /** Drops one entry, for the entry that turned out to be unopenable — a row written under a retired key alias, or one the GCM tag rejects. */
    @Query("DELETE FROM cached_auth_me WHERE cookie_fingerprint = :cookieFingerprint")
    fun delete(cookieFingerprint: String)

    @Query("DELETE FROM cached_auth_me")
    fun deleteAll()
}

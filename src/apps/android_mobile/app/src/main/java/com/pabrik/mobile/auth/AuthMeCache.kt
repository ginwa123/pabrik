package com.pabrik.mobile.auth

import android.content.Context
import com.pabrik.mobile.cache.AuthMeCacheDao
import com.pabrik.mobile.cache.CachedAuthMeEntity
import com.pabrik.mobile.cache.PabrikCacheDatabase
import com.pabrik.mobile.storage.KeystoreSealingCipher
import com.pabrik.mobile.storage.SealingCipher
import java.security.MessageDigest

/** A 30s-TTL cache for `GET /api/auth/me`, mirroring `helpers/authMe.ts`. */
interface AuthMeCache {
    /** A stored response, or null on miss / corrupt entry. */
    fun read(cookieFingerprint: String): CachedAuthMe?

    fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long)

    fun clear()
}

data class CachedAuthMe(
    val body: String,
    val storedAtEpochMillis: Long,
) {
    fun isFresh(nowEpochMillis: Long, ttlMillis: Long): Boolean =
        nowEpochMillis - storedAtEpochMillis < ttlMillis
}

/** The pure half: the key derivation and the freshness rule. */
object AuthMeCacheCodec {
    /** Matches `AUTH_ME_TTL_MS` in `authMe.ts`. */
    const val TTL_MILLIS = 30_000L

    private const val FINGERPRINT_BYTES = 16

    /** A truncated SHA-256 of the session cookie. */
    fun fingerprint(sessionCookie: String): String? {
        if (sessionCookie.isBlank()) return null
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(sessionCookie.toByteArray(Charsets.UTF_8))
        return digest.take(FINGERPRINT_BYTES)
            .joinToString("") { byte -> "%02x".format(byte) }
    }
}

/** [AuthMeCache] on Room: one row per cookie fingerprint, body sealed with a Keystore key. */
class RoomAuthMeCache(
    private val dao: AuthMeCacheDao,
    private val cipher: SealingCipher,
) : AuthMeCache {

    constructor(context: Context) : this(
        dao = PabrikCacheDatabase.get(context).authMeCacheDao(),
        cipher = KeystoreSealingCipher(KEY_ALIAS),
    )

    override fun read(cookieFingerprint: String): CachedAuthMe? {
        val fingerprint = cookieFingerprint.orNull() ?: return null
        return quietly(null) {
            val row = dao.find(fingerprint) ?: return@quietly null
            val body = cipher.open(row.bodySealed)
            if (body == null) {
                // Written under a retired key alias, or a GCM tag that no longer verifies.
                dao.delete(fingerprint)
                return@quietly null
            }
            CachedAuthMe(body = body, storedAtEpochMillis = row.storedAtEpochMillis)
        }
    }

    override fun write(cookieFingerprint: String, responseBody: String, nowEpochMillis: Long) {
        val fingerprint = cookieFingerprint.orNull() ?: return
        val sealed = quietly(null) { cipher.seal(responseBody) } ?: return
        quietly(Unit) {
            dao.put(
                CachedAuthMeEntity(
                    cookieFingerprint = fingerprint,
                    bodySealed = sealed,
                    storedAtEpochMillis = nowEpochMillis,
                ),
            )
        }
    }

    override fun clear() = quietly(Unit) { dao.deleteAll() }

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        // Distinct from the session-cookie and sidebar-cache aliases: this holds an identity, which is a third kind of thing to rotate independently.
        const val KEY_ALIAS = "pabrik_auth_me_key_v1"
    }
}

private fun String?.orNull(): String? = this?.takeIf { it.isNotBlank() }

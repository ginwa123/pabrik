package com.pabrik.mobile.storage

import android.content.Context

/** Where the user was: the workspace they had selected and the chat they had open. */
data class LastPosition(
    val workspaceId: String? = null,
    val sessionId: String? = null,
) {
    /** Nothing worth resuming — a first launch, or a sign-out wiped the store. */
    val isEmpty: Boolean
        get() = workspaceId.isNullOrBlank() && sessionId.isNullOrBlank()
}

/** The user's last position, across process death. */
interface LastPositionStore {
    /** The saved position for an account, or an empty one when there is none. */
    fun read(userId: String?): LastPosition

    /** Writes a position, leaving any field left null as it is — null means "not part of this update", never "forget it". */
    fun save(userId: String?, position: LastPosition)

    /** Records an explicit workspace switch. */
    fun saveWorkspace(userId: String?, workspaceId: String)

    /** Drops every account's position. Called on sign-out. */
    fun clear()
}

/** [LastPositionStore] on `SharedPreferences`. */
class PrefsLastPositionStore(context: Context) : LastPositionStore {

    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
    }

    override fun read(userId: String?): LastPosition = quietly(LastPosition()) {
        LastPosition(
            workspaceId = preferences.readString(workspaceKey(userId)),
            sessionId = preferences.readString(sessionKey(userId)),
        )
    }

    override fun save(userId: String?, position: LastPosition) {
        val workspaceId = position.workspaceId
        val sessionId = position.sessionId
        // A blank id is not a position, and writing one would erase the workspace the user is actually in.
        if (workspaceId == null && sessionId == null) return
        runCatching {
            val editor = preferences.edit()
            workspaceId?.takeIf { it.isNotBlank() }
                ?.let { editor.putString(workspaceKey(userId), it) }
            sessionId?.takeIf { it.isNotBlank() }
                ?.let { editor.putString(sessionKey(userId), it) }
            editor.apply()
        }
    }

    override fun saveWorkspace(userId: String?, workspaceId: String) {
        if (workspaceId.isBlank()) return
        runCatching {
            preferences.edit()
                .putString(workspaceKey(userId), workspaceId)
                .remove(sessionKey(userId))
                .apply()
        }
    }

    override fun clear() {
        runCatching { preferences.edit().clear().apply() }
    }

    private fun android.content.SharedPreferences.readString(key: String): String? =
        getString(key, null)?.takeIf { it.isNotBlank() }

    private fun workspaceKey(userId: String?): String = "workspace:${scopeOf(userId)}"

    private fun sessionKey(userId: String?): String = "session:${scopeOf(userId)}"

    /** The namespace this position belongs to. */
    private fun scopeOf(userId: String?): String =
        userId?.takeIf { it.isNotBlank() } ?: UNSCOPED

    private inline fun <T> quietly(fallback: T, block: () -> T): T = try {
        block()
    } catch (_: Exception) {
        fallback
    }

    private companion object {
        const val PREFERENCES_NAME = "pabrik_position"
        const val UNSCOPED = "unscoped"
    }
}

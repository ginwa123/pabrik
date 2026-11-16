package com.pabrik.mobile.auth

import android.content.Context
import com.pabrik.mobile.storage.EncryptedPrefs

interface SessionStore {
    fun read(): String?
    fun save(cookieValue: String)
    fun clear()
}

class SessionCookieStore(context: Context) : SessionStore {
    private val prefs = EncryptedPrefs(
        context = context,
        preferencesName = EncryptedPrefs.PREFERENCES_NAME,
        keyAlias = EncryptedPrefs.KEY_ALIAS,
    )

    override fun read(): String? = prefs.get(EncryptedPrefs.PAYLOAD_KEY)

    override fun save(cookieValue: String) {
        require(cookieValue.isNotBlank()) { "Session cookie must not be empty" }
        // `require` above is a programming error, so it propagates on purpose; everything after is fail-silent inside EncryptedPrefs.
        prefs.put(EncryptedPrefs.PAYLOAD_KEY, cookieValue)
    }

    override fun clear() = prefs.remove(EncryptedPrefs.PAYLOAD_KEY)
}

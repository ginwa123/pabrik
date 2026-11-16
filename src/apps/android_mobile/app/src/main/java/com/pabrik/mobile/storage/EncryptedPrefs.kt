package com.pabrik.mobile.storage

import android.content.Context

/** SharedPreferences with every value sealed under AES-GCM through the Android Keystore. */
class EncryptedPrefs(
    context: Context,
    preferencesName: String,
    keyAlias: String,
) {
    private val cipher = KeystoreSealingCipher(keyAlias)

    private val preferences by lazy {
        context.applicationContext.getSharedPreferences(
            preferencesName,
            Context.MODE_PRIVATE,
        )
    }

    fun get(key: String): String? = try {
        val payload = preferences.getString(key, null) ?: return null
        cipher.open(payload)?.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        // An entry written under a different Keystore key (a restore to a new device, or a key invalidated by lock-screen changes) is unreadable.
        runCatching { preferences.edit().remove(key).commit() }
        null
    }

    fun put(key: String, value: String) {
        try {
            val sealed = cipher.seal(value) ?: return
            preferences.edit().putString(key, sealed).commit()
        } catch (_: Exception) {
            // Quota or an unavailable Keystore.
        }
    }

    fun remove(key: String) {
        runCatching { preferences.edit().remove(key).commit() }
    }

    /** Used on sign-out: a pending `apply` must not outlive the purge. */
    fun clear() {
        runCatching { preferences.edit().clear().commit() }
    }

    companion object {
        const val PREFERENCES_NAME = "pabrik_auth"
        const val PAYLOAD_KEY = "session_cookie"
        const val KEY_ALIAS = "pabrik_session_key_v1"
    }
}

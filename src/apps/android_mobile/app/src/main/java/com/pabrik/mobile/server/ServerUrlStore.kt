package com.pabrik.mobile.server

import android.content.Context

/** Where the chosen server survives process death. */
interface BaseUrlStore {
    /** The saved address, or null when there is none or it is unreadable. */
    fun read(): String?

    /** Persists [baseUrl]. False means the device refused to write it. */
    fun write(baseUrl: String): Boolean

    fun clear()
}

/** The base URL in `SharedPreferences`. */
class PrefsBaseUrlStore(context: Context) : BaseUrlStore {

    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    override fun read(): String? = try {
        preferences.getString(KEY_BASE_URL, null)?.takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        // A corrupt preferences file is a miss, never a crash on a launch path.
        runCatching { preferences.edit().clear().commit() }
        null
    }

    /** `commit()` rather than `apply()`, despite being on the main thread. */
    override fun write(baseUrl: String): Boolean = try {
        preferences.edit().putString(KEY_BASE_URL, baseUrl).commit()
    } catch (_: Exception) {
        false
    }

    override fun clear() {
        runCatching { preferences.edit().remove(KEY_BASE_URL).commit() }
    }

    private companion object {
        const val PREFERENCES_NAME = "pabrik_server"
        const val KEY_BASE_URL = "base_url"
    }
}

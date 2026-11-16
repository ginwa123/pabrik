package com.pabrik.mobile.auth

import com.pabrik.mobile.BuildConfig
import com.pabrik.mobile.server.ServerUrl

/** Endpoints and the one value that is not a constant of the API: the host. */
object AuthConfig {
    /** The host every request is sent to, right now. */
    val BASE_URL: String get() = ServerUrl.value

    /** The host this build shipped with, and what "reset" returns to. */
    val BUILD_DEFAULT_BASE_URL: String = BuildConfig.API_BASE_URL

    const val LOGIN_PATH = "/api/auth/login"
    const val LOGOUT_PATH = "/api/auth/logout"
    const val ME_PATH = "/api/auth/me"
    const val SESSION_COOKIE_NAME = "pabrik_session"
}

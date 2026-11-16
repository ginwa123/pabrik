package com.pabrik.mobile.recents

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import java.net.HttpURLConnection

/** Reads the sidebar's two lists over the same [AuthTransport] the auth flow uses, so the app keeps a single call site and the in-app network inspector shows … */
sealed interface RecentsResult<out T> {
    data class Loaded<out T>(val value: T) : RecentsResult<T>

    /** The cookie is gone or expired — the caller has to sign in again. */
    data object SignedOut : RecentsResult<Nothing>

    /** Transient: offline, or the server answered with something unusable. */
    data class Unavailable(val message: String) : RecentsResult<Nothing>
}

class RecentsClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    fun loadWorkspaces(): RecentsResult<List<WorkspaceOption>> = get(
        path = RecentsApi.WORKSPACES_PATH,
        parse = RecentsApi::parseWorkspaces,
    )

    /** One page of recents for [workspaceId]. */
    fun loadChats(
        workspaceId: String,
        cursor: String? = null,
        limit: Int = RecentsApi.CHATS_PAGE_LIMIT,
    ): RecentsResult<ChatsPage> = get(
        path = RecentsApi.chatsPath(workspaceId, cursor, limit),
        parse = { body -> RecentsApi.parseChatsPage(body, workspaceId) },
    )

    private fun <T> get(
        path: String,
        parse: (String) -> T,
    ): RecentsResult<T> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.get(
                path = path,
                // The backend reads the session from this cookie and from nowhere else, so it has to ride along on every call.
                headers = sessionCookie
                    ?.let { cookie -> mapOf("Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie") }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        // A 401 means the cookie is gone or expired; a retry cannot fix that.
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(messageForStatus(response.statusCode))
        }

        return try {
            RecentsResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            RecentsResult.Unavailable("The server sent a response this app could not read.")
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load your sidebar. Try again."
        else -> "Could not load your sidebar. Try again."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
    }
}

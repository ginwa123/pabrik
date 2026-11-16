package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.net.HttpURLConnection

/** The three reads and one write the "New task" form needs that are **not** the create POST: the board's columns, the profiles it can run under, the server's home … */
class KanbanClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    /** The board's columns, for the form's column chip. */
    fun loadColumns(
        workspaceId: String,
        itemId: String,
    ): RecentsResult<List<KanbanColumn>> = get(KanbanApi.columnsPath(workspaceId, itemId)) {
        // `parseColumns` returns null for a body that is not a columns list, and the generic `get` turns a thrown parse error into Unavailable — so the failure has to be …
        KanbanApi.parseColumns(it)
            ?: throw IllegalStateException("Response was not a kanban columns list")
    }

    /** The profiles a card can be created under, as raw names. */
    fun loadProfileNames(): RecentsResult<List<String>> =
        get(com.pabrik.mobile.chat.ChatApi.profilesPath()) { body ->
            com.pabrik.mobile.chat.ChatApi.parseProfiles(body).profiles.map { it.name }
        }

    /** The backend user's `$HOME`, used only to prefill the worktree path. */
    fun loadServerHome(): RecentsResult<String> = get(KanbanApi.serverHomePath()) { body ->
        KanbanApi.parseServerHome(body)
    }

    /** Move a freshly created card into the column the reader chose. */
    fun moveTaskToColumn(
        workspaceId: String,
        itemId: String,
        taskId: String,
        columnId: String,
        position: Int = 0,
    ): RecentsResult<Unit> {
        if (columnId.isBlank()) return RecentsResult.Loaded(Unit)

        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.patch(
                path = KanbanApi.moveTaskPath(workspaceId, itemId, taskId),
                body = KanbanApi.moveTaskBody(columnId, position),
                headers = sessionCookie
                    ?.let { cookie ->
                        mapOf(
                            "Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
                            "Content-Type" to "application/json",
                        )
                    }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(moveMessageForStatus(response.statusCode))
        }
        return RecentsResult.Loaded(Unit)
    }

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
                // The backend reads the session from this cookie and nowhere else, so it rides along on every call.
                headers = sessionCookie
                    ?.let { cookie -> mapOf("Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie") }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(messageForStatus(response.statusCode))
        }

        return try {
            RecentsResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    /** Says "board", not "projects" and not "sidebar". */
    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load this board. Try again."
        else -> "Could not load this board. Try again."
    }

    /** The failed *move*, said as its own promise. */
    private fun moveMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The task was created, but the server could not move it to that column."
        else -> "The task was created, but could not be moved to that column."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
        const val UNREADABLE_RESPONSE_MESSAGE = "The server sent a response this app could not read."
    }
}

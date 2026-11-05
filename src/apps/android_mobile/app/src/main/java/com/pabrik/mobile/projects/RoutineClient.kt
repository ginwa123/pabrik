package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.net.HttpURLConnection

class RoutineClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    fun loadRoutine(workspaceId: String, itemId: String): RecentsResult<WorkspaceRoutine> =
        get(RoutineApi.routinePath(workspaceId, itemId)) { body ->
            RoutineApi.parseRoutine(body)
                ?: throw IllegalStateException("Response was not a routine")
        }

    fun createRoutine(
        workspaceId: String,
        name: String,
        path: String,
        description: String = "",
        instruction: String = "",
        schedule: String = "",
        enabled: Boolean = true,
    ): RecentsResult<Pair<ProjectSummary, WorkspaceRoutine>> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }
        val response = try {
            transport.post(
                path = RoutineApi.createPath(workspaceId),
                body = RoutineApi.createBody(name, path, description, instruction, schedule, enabled),
                headers = writeHeaders(sessionCookie),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(createMessageForStatus(response.statusCode))
        }
        val created = try {
            RoutineApi.parseCreatedRoutine(response.body)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        return RecentsResult.Loaded(created)
    }

    fun updateRoutine(
        workspaceId: String,
        itemId: String,
        description: String? = null,
        instruction: String? = null,
        schedule: String? = null,
        selectedProfileModel: String? = null,
        enabled: Boolean? = null,
    ): RecentsResult<WorkspaceRoutine> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }
        val response = try {
            transport.patch(
                path = RoutineApi.routinePath(workspaceId, itemId),
                body = RoutineApi.updateBody(
                    description, instruction, schedule, selectedProfileModel, enabled,
                ),
                headers = writeHeaders(sessionCookie),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(updateMessageForStatus(response.statusCode))
        }
        val routine = try {
            RoutineApi.parseRoutine(response.body)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        return RecentsResult.Loaded(routine)
    }

    fun runRoutine(
        workspaceId: String,
        itemId: String,
        routineId: String,
    ): RecentsResult<String> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }
        val response = try {
            transport.post(
                path = RoutineApi.runPath(workspaceId, itemId, routineId),
                body = "",
                headers = writeHeaders(sessionCookie),
            )
        } catch (_: Exception) {
            return RecentsResult.Unavailable(unreachableMessage())
        }
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return RecentsResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(runMessageForStatus(response.statusCode))
        }
        val sessionId = try {
            RoutineApi.parseRunSessionId(response.body)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        return RecentsResult.Loaded(sessionId)
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

    private fun writeHeaders(sessionCookie: String?): Map<String, String> =
        sessionCookie
            ?.let { cookie ->
                mapOf(
                    "Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie",
                    "Content-Type" to "application/json",
                )
            }
            .orEmpty()

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load this routine. Try again."
        else -> "Could not load this routine. Try again."
    }

    private fun createMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not create that routine. Try again."
        else -> "Could not create that routine. Check the name and folder and try again."
    }

    private fun updateMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not save this routine. Try again."
        else -> "Could not save this routine. Check the schedule and try again."
    }

    private fun runMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not run this routine. Try again."
        else -> "Could not run this routine. Try again."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
        const val UNREADABLE_RESPONSE_MESSAGE = "The server sent a response this app could not read."
    }
}

package com.pabrik.mobile.projects

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.recents.RecentsResult
import java.net.HttpURLConnection

/** Reads the drawer's project lists over the same [AuthTransport] the auth flow and [com.pabrik.mobile.recents.RecentsClient] use, so the app keeps a single call … */
class ProjectsClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    /** Every project in one workspace. Not paginated — the endpoint takes none. */
    fun loadProjects(workspaceId: String): RecentsResult<List<ProjectSummary>> = get(
        path = ProjectsApi.itemsPath(workspaceId),
        parse = ProjectsApi::parseItems,
    )

    /** One page of [itemId]'s chats. */
    fun loadProjectChats(
        workspaceId: String,
        itemId: String,
        cursor: String? = null,
        limit: Int = ProjectsApi.TASKS_PAGE_LIMIT,
    ): RecentsResult<ProjectChatsPage> = get(
        path = ProjectsApi.tasksPath(workspaceId, itemId, cursor, limit),
        parse = { body -> ProjectsApi.parseProjectChatsPage(body, itemId) },
    )

    /** Create a task under a project — an ordinary chat, a memory file, or a card on a kanban board. */
    fun createTask(
        workspaceId: String,
        itemId: String,
        request: CreateTaskRequest,
    ): RecentsResult<ProjectChat> {
        val isKanbanCard = request is CreateTaskRequest.KanbanTask

        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.post(
                path = if (isKanbanCard) {
                    ProjectsApi.createKanbanTaskPath(workspaceId, itemId)
                } else {
                    ProjectsApi.createTaskPath(workspaceId, itemId)
                },
                body = ProjectsApi.createTaskBody(request),
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
            return RecentsResult.Unavailable(createMessageForStatus(response.statusCode))
        }

        // The two parsers are picked together with the two paths because getting this wrong is silent, not loud: parse a `{"task":…}` envelope with the bare-row parser …
        val created = try {
            if (isKanbanCard) {
                ProjectsApi.parseCreatedKanbanTask(response.body, itemId)
            } else {
                ProjectsApi.parseCreatedTask(response.body, itemId)
            }
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)

        return RecentsResult.Loaded(created)
    }

    /** Cold-start fallback for the drawer's "New Chat" row: the workspace's default project, created server-side when there is none. */
    suspend fun getOrCreateDefaultProject(
        workspaceId: String,
    ): RecentsResult<ProjectSummary> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return RecentsResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.post(
                path = ProjectsApi.defaultProjectPath(workspaceId),
                // No body: this is a command ("give me the default"), and the name and path are fixed by the invariant.
                body = "",
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
        // 200 = the default already existed, 201 = this call created it.
        if (response.statusCode !in 200..299) {
            return RecentsResult.Unavailable(createMessageForStatus(response.statusCode))
        }

        val project = try {
            ProjectsApi.parseDefaultProject(response.body)
        } catch (_: Exception) {
            null
        } ?: return RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)

        return RecentsResult.Loaded(project)
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
            RecentsResult.Unavailable(UNREADABLE_RESPONSE_MESSAGE)
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    /** These say "projects", not "sidebar". */
    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load your projects. Try again."
        else -> "Could not load your projects. Try again."
    }

    /** The same statuses, said about a *write*. */
    private fun createMessageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not create that. Try again."
        // 400 and 403 land here.
        else -> "Could not create that. Check the name and try again."
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session. Try signing in again."
        const val UNREADABLE_RESPONSE_MESSAGE = "The server sent a response this app could not read."
    }
}

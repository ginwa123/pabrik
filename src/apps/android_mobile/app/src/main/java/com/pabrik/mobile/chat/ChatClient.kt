package com.pabrik.mobile.chat

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthHttpResponse
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import com.pabrik.mobile.worker.WorkerApi
import org.json.JSONObject
import java.net.HttpURLConnection

sealed interface ChatResult<out T> {
    data class Loaded<out T>(val value: T) : ChatResult<T>

    /** The cookie is gone or expired — the caller has to sign in again. */
    data object SignedOut : ChatResult<Nothing>

    /** The server rejected the request. The message is worth keeping. */
    data class Rejected(val message: String) : ChatResult<Nothing>

    /** Transient: offline, or the server answered with something unusable. */
    data class Unavailable(val message: String) : ChatResult<Nothing>
}

/** The chat endpoints, over the same [AuthTransport] the auth flow and the sidebar use, so the in-app network inspector records the exact bytes the chat sent … */
class ChatClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    fun loadMessages(
        sessionId: String,
        limit: Int = ChatApi.MESSAGES_PAGE_LIMIT,
        cursor: String? = null,
        direction: String = "asc",
    ): ChatResult<ChatPage> = get(
        path = ChatApi.messagesPath(sessionId, limit, cursor, direction),
        parse = ChatApi::parseMessages,
    )

    /** Queues a turn. */
    fun sendMessage(
        sessionId: String,
        message: String,
        cwd: String = "",
        imageUrls: List<String> = emptyList(),
        videoUrls: List<String> = emptyList(),
        selectedProfileModel: String = "",
    ): ChatResult<Unit> {
        val body = ChatApi.sendMessageBody(
            sessionId = sessionId,
            message = message,
            cwd = cwd,
            imageUrls = imageUrls,
            videoUrls = videoUrls,
            selectedProfileModel = selectedProfileModel,
        )
        val response = try {
            transport.post(
                path = SEND_PATH,
                body = body,
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "Your message could not be sent. Try again.")
    }

    /** Every configured profile, and the reader's active default. */
    fun loadProfiles(): ChatResult<ProfilesPage> = get(
        path = ChatApi.profilesPath(),
        parse = ChatApi::parseProfiles,
    )

    /** Saves which profile this chat runs on. */
    fun updateSelectedProfile(
        sessionId: String,
        profileName: String,
    ): ChatResult<String> {
        val response = try {
            transport.put(
                path = ChatApi.sessionPath(sessionId),
                body = ChatApi.updateSessionBody(selectedProfileModel = profileName),
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(
            response,
            "That model could not be saved. Try again.",
            parse = { body -> JSONObject(body).optNullableString("selected_profile_model").orEmpty() },
        )
    }

    /** The turns waiting behind this chat's current run. */
    fun loadQueuedMessages(sessionId: String): ChatResult<List<QueuedChatMessage>> = get(
        path = ChatApi.queueMessagesPath(sessionId),
        parse = ChatApi::parseQueuedMessages,
    )

    fun stopRun(sessionId: String): ChatResult<Unit> {
        val response = try {
            transport.post(
                path = ChatApi.stopPath(sessionId),
                body = "{}",
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "Could not stop the run. Try again.")
    }

    /** Answers a pending `ask_user` question, which is what resumes the run. */
    fun answerQuestion(
        sessionId: String,
        questionId: String? = null,
        toolCallId: String? = null,
        answer: String? = null,
        skip: Boolean = false,
    ): ChatResult<Unit> {
        val response = try {
            transport.post(
                path = ChatApi.answerPath(sessionId),
                body = ChatApi.answerQuestionBody(
                    questionId = questionId,
                    toolCallId = toolCallId,
                    answer = answer,
                    skip = skip,
                ),
                headers = authenticatedHeaders(json = true),
            )
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretWrite(response, "The answer could not be sent. Try again.")
    }

    /** The in-flight partial text for a run that is still going. */
    fun loadStreamSnapshot(sessionId: String): ChatResult<String> = get(
        path = ChatApi.streamSnapshotPath(sessionId),
        parse = { body -> JSONObject(body).optNullableString("content").orEmpty() },
    )

    /** The sessions with a live worker, as a bootstrap for the running set that [com.pabrik.mobile.worker.RunningSessionsStore] holds. */
    fun loadRunningSessions(): ChatResult<Set<String>> = get(
        path = WorkerApi.workersPath(),
        parse = WorkerApi::parseRunningSessionIds,
    )

    /** Whether a worker is registered on this one session right now. */
    fun isSessionRunning(sessionId: String): ChatResult<Boolean> =
        when (val result = get(
            path = WorkerApi.workersPathForSession(sessionId),
            parse = WorkerApi::parseRunningSessionIds,
        )) {
            // A null parse comes back as `Unavailable`, never as `false`: an envelope without the array is not the server saying nothing is running.
            is ChatResult.Loaded -> ChatResult.Loaded(sessionId in result.value)
            is ChatResult.SignedOut -> ChatResult.SignedOut
            is ChatResult.Rejected -> result
            is ChatResult.Unavailable -> result
        }

    private fun <T : Any> get(
        path: String,
        parse: (String) -> T?,
    ): ChatResult<T> {
        val response = try {
            transport.get(path = path, headers = authenticatedHeaders(json = false))
        } catch (_: Exception) {
            return ChatResult.Unavailable(unreachableMessage())
        }
        return interpretRead(response, parse)
    }

    /** [parse] returns null when the payload was readable but the field this read needs was **absent** — which is not the same answer as an empty one, and the … */
    private fun <T : Any> interpretRead(
        response: AuthHttpResponse,
        parse: (String) -> T?,
    ): ChatResult<T> {
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return ChatResult.SignedOut
        }
        if (response.statusCode == HttpURLConnection.HTTP_NOT_FOUND) {
            // A 404 here means "not yours" as often as "does not exist" — the backend collapses both.
            return ChatResult.Rejected("That chat no longer exists.")
        }
        if (response.statusCode !in 200..299) {
            return ChatResult.Unavailable(messageForStatus(response.statusCode))
        }
        return try {
            // Null and "threw" are the same answer here on purpose: both mean the payload did not carry a field this read needs, and neither is an answer about the server's …
            parse(response.body)?.let { ChatResult.Loaded(it) }
                ?: ChatResult.Unavailable("The server sent a response this app could not read.")
        } catch (_: Exception) {
            ChatResult.Unavailable("The server sent a response this app could not read.")
        }
    }

    /** A write whose reply carries nothing this client needs. */
    private fun interpretWrite(
        response: AuthHttpResponse,
        rejectionMessage: String,
    ): ChatResult<Unit> = interpretWrite(response, rejectionMessage, parse = { })

    /** A write that answers with a value, run through [parse]. */
    private fun <T> interpretWrite(
        response: AuthHttpResponse,
        rejectionMessage: String,
        parse: (String) -> T,
    ): ChatResult<T> {
        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return ChatResult.SignedOut
        }
        // 4xx here means the request itself was wrong, so a retry sends the same wrong request. 5xx and timeouts are worth retrying.
        if (response.statusCode in 400..499) {
            return ChatResult.Rejected(rejectionMessage)
        }
        if (response.statusCode !in 200..299) {
            return ChatResult.Unavailable(messageForStatus(response.statusCode))
        }
        return try {
            ChatResult.Loaded(parse(response.body))
        } catch (_: Exception) {
            ChatResult.Unavailable("The server sent a response this app could not read.")
        }
    }

    private fun authenticatedHeaders(json: Boolean): Map<String, String> {
        val cookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            null
        }
        return buildMap {
            if (json) put("Content-Type", "application/json")
            // The backend reads the session from this cookie and from nowhere else — no bearer token, no CSRF token — so it rides on every call.
            cookie?.let { put("Cookie", "${AuthConfig.SESSION_COOKIE_NAME}=$it") }
        }
    }

    private fun unreachableMessage(): String =
        "Could not reach ${AuthConfig.BASE_URL}. Check your connection."

    private fun messageForStatus(statusCode: Int): String = when {
        statusCode == HttpURLConnection.HTTP_CLIENT_TIMEOUT -> unreachableMessage()
        statusCode in 500..599 -> "The server could not load this chat. Try again."
        else -> "Could not load this chat. Try again."
    }

    companion object {
        /** Sending is a create-or-queue POST, so the path is the bare collection. */
        const val SEND_PATH = "/api/llm/session"
    }
}

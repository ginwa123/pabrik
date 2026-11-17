package com.pabrik.mobile.workspace

import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.AuthTransport
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionStore
import java.net.HttpURLConnection

sealed interface WorkspaceDataResult<out T> {
    data class Loaded<out T>(val value: T) : WorkspaceDataResult<T>
    data object SignedOut : WorkspaceDataResult<Nothing>
    data class Unavailable(val message: String) : WorkspaceDataResult<Nothing>
}

class WorkspaceDataClient(
    private val sessionStore: SessionStore,
    baseUrlProvider: () -> String = { AuthConfig.BASE_URL },
    httpTransport: AuthTransport? = null,
) {
    private val transport: AuthTransport =
        httpTransport ?: HttpsAuthTransport(baseUrlProvider)

    fun loadSecrets(workspaceId: String): WorkspaceDataResult<List<SecretEntry>> = get(
        path = WorkspaceDataApi.secretsPath(workspaceId),
        parse = WorkspaceDataApi::parseSecrets,
    )

    fun loadMembers(workspaceId: String): WorkspaceDataResult<List<MemberEntry>> = get(
        path = WorkspaceDataApi.membersPath(workspaceId),
        parse = WorkspaceDataApi::parseMembers,
    )

    fun loadSkills(workspaceId: String): WorkspaceDataResult<List<SkillEntry>> = get(
        path = WorkspaceDataApi.skillsPath(workspaceId),
        parse = WorkspaceDataApi::parseSkills,
    )

    fun loadMemories(workspaceId: String): WorkspaceDataResult<List<MemoryEntry>> = get(
        path = WorkspaceDataApi.memoriesPath(workspaceId),
        parse = WorkspaceDataApi::parseMemories,
    )

    fun loadUsage(workspaceId: String): WorkspaceDataResult<UsageData> = get(
        path = WorkspaceDataApi.usagePath(workspaceId),
        parse = WorkspaceDataApi::parseUsage,
    )

    fun loadConfig(workspaceId: String): WorkspaceDataResult<ConfigData> = get(
        path = WorkspaceDataApi.configPath(workspaceId),
        parse = WorkspaceDataApi::parseConfig,
    )

    fun loadDocuments(workspaceId: String): WorkspaceDataResult<List<DocumentEntry>> = get(
        path = WorkspaceDataApi.itemsPath(workspaceId),
        parse = WorkspaceDataApi::parseDocuments,
    )

    private fun <T> get(
        path: String,
        parse: (String) -> T,
    ): WorkspaceDataResult<T> {
        val sessionCookie = try {
            sessionStore.read()
        } catch (_: Exception) {
            return WorkspaceDataResult.Unavailable(SESSION_ERROR_MESSAGE)
        }

        val response = try {
            transport.get(
                path = path,
                headers = sessionCookie
                    ?.let { cookie -> mapOf("Cookie" to "${AuthConfig.SESSION_COOKIE_NAME}=$cookie") }
                    .orEmpty(),
            )
        } catch (_: Exception) {
            return WorkspaceDataResult.Unavailable(UNREACHABLE_MESSAGE)
        }

        if (response.statusCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
            return WorkspaceDataResult.SignedOut
        }
        if (response.statusCode !in 200..299) {
            return WorkspaceDataResult.Unavailable("Server returned ${response.statusCode}.")
        }

        val parsed = try {
            parse(response.body)
        } catch (_: Exception) {
            return WorkspaceDataResult.Unavailable(UNREADABLE_MESSAGE)
        }
        return WorkspaceDataResult.Loaded(parsed)
    }

    private companion object {
        const val SESSION_ERROR_MESSAGE = "Could not read the saved session."
        const val UNREACHABLE_MESSAGE = "Could not reach the server. Check your connection."
        const val UNREADABLE_MESSAGE = "The server returned an unexpected response."
    }
}

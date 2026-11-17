package com.pabrik.mobile.workspace

import android.app.Application
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.pabrik.mobile.auth.AuthConfig
import com.pabrik.mobile.auth.HttpsAuthTransport
import com.pabrik.mobile.auth.SessionCookieStore
import com.pabrik.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class WorkspaceDataState(
    val workspaceId: String = "",
    val secrets: List<SecretEntry> = emptyList(),
    val members: List<MemberEntry> = emptyList(),
    val skills: List<SkillEntry> = emptyList(),
    val memories: List<MemoryEntry> = emptyList(),
    val usage: UsageData? = null,
    val config: ConfigData? = null,
    val documents: List<DocumentEntry> = emptyList(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
)

class WorkspaceDataViewModel(
    private val client: WorkspaceDataClient,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel() {
    private val _uiState = MutableStateFlow(WorkspaceDataState())
    val uiState: StateFlow<WorkspaceDataState> = _uiState.asStateFlow()

    private var loadJob: Job? = null

    fun load(workspaceId: String) {
        if (workspaceId.isBlank()) return
        loadJob?.cancel()
        loadJob = viewModelScope.launch {
            _uiState.value = WorkspaceDataState(workspaceId = workspaceId, isLoading = true)
            val bundle = withContext(ioDispatcher) {
                val errors = mutableListOf<String>()
                fun <T> unwrap(result: WorkspaceDataResult<T>, label: String): T? = when (result) {
                    is WorkspaceDataResult.Loaded -> result.value
                    is WorkspaceDataResult.SignedOut -> {
                        errors.add("Session expired. Sign in again.")
                        null
                    }
                    is WorkspaceDataResult.Unavailable -> {
                        errors.add("$label: ${result.message}")
                        null
                    }
                }
                LoadedBundle(
                    secrets = unwrap(client.loadSecrets(workspaceId), "Secrets"),
                    members = unwrap(client.loadMembers(workspaceId), "Members"),
                    skills = unwrap(client.loadSkills(workspaceId), "Skills"),
                    memories = unwrap(client.loadMemories(workspaceId), "Memories"),
                    usage = unwrap(client.loadUsage(workspaceId), "Usage"),
                    config = unwrap(client.loadConfig(workspaceId), "Config"),
                    documents = unwrap(client.loadDocuments(workspaceId), "Documents"),
                    errors = errors.toList(),
                )
            }
            _uiState.value = WorkspaceDataState(
                workspaceId = workspaceId,
                secrets = bundle.secrets.orEmpty(),
                members = bundle.members.orEmpty(),
                skills = bundle.skills.orEmpty(),
                memories = bundle.memories.orEmpty(),
                usage = bundle.usage,
                config = bundle.config,
                documents = bundle.documents.orEmpty(),
                isLoading = false,
                errorMessage = bundle.errors.firstOrNull(),
            )
        }
    }

    private data class LoadedBundle(
        val secrets: List<SecretEntry>?,
        val members: List<MemberEntry>?,
        val skills: List<SkillEntry>?,
        val memories: List<MemoryEntry>?,
        val usage: UsageData?,
        val config: ConfigData?,
        val documents: List<DocumentEntry>?,
        val errors: List<String>,
    )

    companion object {
        fun factory(application: Application): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                WorkspaceDataViewModel(
                    client = WorkspaceDataClient(
                        sessionStore = SessionCookieStore(application),
                        httpTransport = RecordingAuthTransport(
                            HttpsAuthTransport { AuthConfig.BASE_URL },
                        ),
                    ),
                )
            }
        }
    }
}

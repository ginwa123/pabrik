package com.pabrik.mobile.auth

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.pabrik.mobile.network.RecordingAuthTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class SessionPhase {
    Restoring,
    NeedsLogin,
    NeedsRetry,
    Authenticated,
}

data class AuthUiState(
    val phase: SessionPhase = SessionPhase.Restoring,
    val isAuthenticating: Boolean = false,
    /** A sign-out is in flight. */
    val isLoggingOut: Boolean = false,
    val errorMessage: String? = null,
    /** The signed-in account, or null when auth is off / no one is signed in. */
    val userId: String? = null,
    /** False when the server runs without `--auth`. */
    val isAuthEnabled: Boolean = false,
    /** Shown beside the sign-out action so the user knows who they are ending. */
    val userEmail: String? = null,
)

/** The one [AuthResult] -> [AuthUiState] rule. */
internal fun authUiStateFor(result: AuthResult): AuthUiState = when (result) {
    is AuthResult.Authenticated -> AuthUiState(
        phase = SessionPhase.Authenticated,
        userId = result.user.id.takeIf { id -> id.isNotBlank() },
        isAuthEnabled = true,
        userEmail = result.user.email,
    )

    // Authenticated, but nobody to be: the server is running open.
    AuthResult.AuthDisabled -> AuthUiState(phase = SessionPhase.Authenticated)

    AuthResult.NoSession -> AuthUiState(phase = SessionPhase.NeedsLogin)

    is AuthResult.Rejected -> AuthUiState(
        phase = SessionPhase.NeedsLogin,
        errorMessage = result.message,
    )

    is AuthResult.Unavailable -> AuthUiState(
        phase = SessionPhase.NeedsRetry,
        errorMessage = result.message,
    )
}

/** The sign-out path's own mapping: the session is being ended, so every outcome lands on the login screen. */
internal fun signedOutUiStateFor(result: AuthResult): AuthUiState = when (result) {
    is AuthResult.Unavailable -> AuthUiState(
        phase = SessionPhase.NeedsLogin,
        errorMessage = result.message,
    )

    else -> AuthUiState(phase = SessionPhase.NeedsLogin)
}

class AuthViewModel(application: Application) : AndroidViewModel(application) {
    private val client = AuthClient(
        sessionStore = SessionCookieStore(application),
        // Recording wraps the real transport so the inspector shows the same bytes the auth flow sent, including a rejected sign-in.
        httpTransport = RecordingAuthTransport(HttpsAuthTransport { AuthConfig.BASE_URL }),
        meCache = RoomAuthMeCache(application),
    )
    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()
    private var restoreJob: Job? = null

    init {
        restoreSession()
    }

    fun restoreSession(forceRefresh: Boolean = false) {
        restoreJob?.cancel()
        restoreJob = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.restoreSession(forceRefresh)
            }
            _uiState.value = authUiStateFor(result)
        }
    }

    fun login(email: String, password: String) {
        if (_uiState.value.isAuthenticating) return
        _uiState.update { it.copy(isAuthenticating = true, errorMessage = null) }

        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.login(email = email, password = password)
            }
            _uiState.value = when (result) {
                // Sign-in is the one result that is not the same failure as the same failure during a restore: a dropped connection here must offer the form again, not a "Try …
                is AuthResult.Unavailable -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = result.message,
                )

                AuthResult.NoSession -> AuthUiState(
                    phase = SessionPhase.NeedsLogin,
                    errorMessage = "Sign-in did not complete. Try again.",
                )

                else -> authUiStateFor(result)
            }
        }
    }

    /** The reader pointed the app at a different server. */
    fun onServerChanged() {
        restoreJob?.cancel()
        if (_uiState.value.isLoggingOut) return
        _uiState.update { it.copy(isLoggingOut = true) }

        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { client.forgetSession() }
            // A device that could not drop its own cookie has to say so, rather than showing a login form that will silently be signed straight back in by the cookie still …
            _uiState.value = when (result) {
                is AuthResult.Unavailable -> signedOutUiStateFor(result)
                else -> AuthUiState(phase = SessionPhase.NeedsLogin)
            }
        }
    }

    /** Sign-out. */
    fun logout() {
        if (_uiState.value.isLoggingOut) return
        _uiState.update { it.copy(isLoggingOut = true) }

        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                client.logout()
            }
            _uiState.value = signedOutUiStateFor(result)
        }
    }
}

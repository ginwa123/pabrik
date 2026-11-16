package com.pabrik.mobile.auth

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The sign-out feature hangs off two pieces of state this file pins down: the sidebar's "Log out" row is gated on [AuthUiState.isAuthEnabled] and labelled with … */
class AuthUiStateMapperTest {
    private val user = AuthUser(
        id = "user-1",
        email = "ada@example.com",
        name = "Ada",
        role = "member",
    )

    @Test
    fun anAuthenticatedSessionEnablesTheSignOutRowAndNamesTheAccount() {
        val state = authUiStateFor(AuthResult.Authenticated(user))

        assertEquals(SessionPhase.Authenticated, state.phase)
        assertTrue("a live session is what the sign-out row exists for", state.isAuthEnabled)
        assertEquals("ada@example.com", state.userEmail)
        assertEquals("user-1", state.userId)
        assertFalse(state.isLoggingOut)
    }

    @Test
    fun anOpenServerHasNothingToSignOutOf() {
        // `auth_enabled=false` is the only result that produces this phase with no user.
        val state = authUiStateFor(AuthResult.AuthDisabled)

        assertEquals(SessionPhase.Authenticated, state.phase)
        assertFalse("there is no session to end, so the row must stay hidden", state.isAuthEnabled)
        assertNull(state.userEmail)
        assertNull(state.userId)
    }

    @Test
    fun aUserIdOfOnlyWhitespaceStillCountsAsAuthenticated() {
        // `parseUser` never yields a blank email, so an authenticated result with one cannot be constructed by the real client — but a blank *id* can, and the sidebar …
        val state = authUiStateFor(AuthResult.Authenticated(user.copy(id = "   ")))

        assertTrue(state.isAuthEnabled)
        assertEquals("ada@example.com", state.userEmail)
        assertNull("a blank id must not become a cache namespace", state.userId)
    }

    @Test
    fun aRejectedSignInAsksForCredentialsAgain() {
        val state = authUiStateFor(AuthResult.Rejected("Invalid email or password."))

        assertEquals(SessionPhase.NeedsLogin, state.phase)
        assertEquals("Invalid email or password.", state.errorMessage)
        assertFalse(state.isAuthEnabled)
    }

    @Test
    fun anUnreachableServerDuringRestoreOffersARetry() {
        // NeedsRetry, not NeedsLogin: the saved session may still be good, and the retry screen is the only place that can find out.
        val state = authUiStateFor(AuthResult.Unavailable("Could not reach Pabrik."))

        assertEquals(SessionPhase.NeedsRetry, state.phase)
        assertEquals("Could not reach Pabrik.", state.errorMessage)
    }

    @Test
    fun aMissingSessionGoesStraightToTheLoginForm() {
        val state = authUiStateFor(AuthResult.NoSession)

        assertEquals(SessionPhase.NeedsLogin, state.phase)
        assertNull(state.errorMessage)
        assertFalse(state.isAuthEnabled)
    }

    @Test
    fun everySignedOutOutcomeEndsOnTheLoginForm() {
        val outcomes = listOf(
            AuthResult.NoSession,
            AuthResult.Authenticated(user),
            AuthResult.AuthDisabled,
            AuthResult.Rejected("nope"),
            AuthResult.Unavailable("Could not clear the saved session."),
        )

        outcomes.forEach { result ->
            val state = signedOutUiStateFor(result)
            assertEquals("sign-out must land on the login form: $result", SessionPhase.NeedsLogin, state.phase)
            assertFalse("no account survives a sign-out: $result", state.isAuthEnabled)
            assertNull("the outgoing account must not linger in state: $result", state.userEmail)
            assertNull("nor its cache namespace: $result", state.userId)
            // A finished sign-out has to hand the button back, or the login screen it returns to would arrive with a dead control still latched.
            assertFalse(state.isLoggingOut)
        }
    }

    @Test
    fun aFailedLocalSignOutTellsTheUserOnTheLoginForm() {
        // The cookie is still on disk in this case, so the next launch would restore the session.
        val state = signedOutUiStateFor(AuthResult.Unavailable("Could not clear the saved session."))

        assertEquals(SessionPhase.NeedsLogin, state.phase)
        assertEquals("Could not clear the saved session.", state.errorMessage)
    }
}

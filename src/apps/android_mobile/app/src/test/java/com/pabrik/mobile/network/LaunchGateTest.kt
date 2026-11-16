package com.pabrik.mobile.network

import com.pabrik.mobile.auth.SessionPhase
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The launch gate: the one rule that decides whether the reader sees a screen yet, and nothing else. */
class LaunchGateTest {

    @Test
    fun `the shell is held until the resume has answered`() {
        // The whole point.
        assertTrue(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                resumeDecided = false,
            ),
        )
    }

    @Test
    fun `an answered resume with nothing to open reveals the shell`() {
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                resumeDecided = true,
            ),
        )
    }

    @Test
    fun `a resumed chat is held until its transcript is where it belongs`() {
        // Not until the route exists and not until the state says loaded: the auto-scroll to the newest turn is issued after both, and revealing before it is the jump …
        assertTrue(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.chat("sess_c"),
                resumeDecided = true,
                resumedSessionId = "sess_c",
                transcriptSettled = false,
            ),
        )
    }

    @Test
    fun `a settled transcript reveals the chat`() {
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.chat("sess_c"),
                resumeDecided = true,
                resumedSessionId = "sess_c",
                transcriptSettled = true,
            ),
        )
    }

    @Test
    fun `a resumed chat stays revealed after the reader leaves it`() {
        // Back returns to the shell, and the launch is over.
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                resumeDecided = true,
                resumedSessionId = "sess_c",
                transcriptSettled = true,
            ),
        )
    }

    @Test
    fun `the launch screen is never covered by another launch screen`() {
        // `Restoring` already paints `AuthRestoringScreen` in the shell.
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Restoring,
                currentRoute = PabrikRoutes.SHELL,
                resumeDecided = false,
            ),
        )
    }

    @Test
    fun `a screen with controls of its own is never covered`() {
        // The two phases where the shell is not a shell: a sign-in form and a "Try again".
        SessionPhase.entries
            .filter { it != SessionPhase.Authenticated }
            .forEach { phase ->
                assertFalse(
                    "covered during $phase",
                    gateIsUp(
                        authPhase = phase,
                        currentRoute = PabrikRoutes.SHELL,
                        resumeDecided = false,
                        resumedSessionId = "sess_c",
                        transcriptSettled = false,
                    ),
                )
            }
    }

    @Test
    fun `a deep link is a destination the user chose, not one to wait for`() {
        // `ResumePlan` never answers off the shell, so waiting for an answer here is a splash the reader cannot leave.
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.chat("sess_x"),
                resumeDecided = false,
                resumedSessionId = null,
            ),
        )
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.NETWORK,
                resumeDecided = false,
            ),
        )
    }

    @Test
    fun `no destination yet is the launch, not somewhere else`() {
        // `NavHost` has not produced its start destination yet on the first frames of a graph, so `currentRoute` is null while this *is* the shell.
        assertTrue(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = null,
                resumeDecided = false,
            ),
        )
        assertFalse(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = null,
                resumeDecided = true,
            ),
        )
    }

    @Test
    fun `a plan that has not been read yet counts as still asking`() {
        // The store is read on IO, so for the first frames of a launch the plan is null.
        assertTrue(
            gateIsUp(
                authPhase = SessionPhase.Authenticated,
                currentRoute = PabrikRoutes.SHELL,
                resumeDecided = false,
            ),
        )
    }

    private fun gateIsUp(
        authPhase: SessionPhase,
        currentRoute: String?,
        resumeDecided: Boolean,
        resumedSessionId: String? = null,
        transcriptSettled: Boolean = false,
    ) = launchGateIsUp(
        authPhase = authPhase,
        currentRoute = currentRoute,
        resumeDecided = resumeDecided,
        resumedSessionId = resumedSessionId,
        transcriptSettled = transcriptSettled,
    )
}

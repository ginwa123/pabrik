package com.pabrik.mobile.network

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import com.pabrik.mobile.auth.AuthRestoringScreen
import com.pabrik.mobile.auth.SessionPhase
import com.pabrik.mobile.ui.PabrikBackground

/** Whether an opaque gate is held over the whole graph while a launch finishes deciding what to show. */
internal fun launchGateIsUp(
    authPhase: SessionPhase,
    currentRoute: String?,
    resumeDecided: Boolean,
    resumedSessionId: String?,
    transcriptSettled: Boolean,
): Boolean = when (authPhase) {
    // Rule 1. The shell is already a splash, a form or a retry.
    SessionPhase.Restoring,
    SessionPhase.NeedsLogin,
    SessionPhase.NeedsRetry,
    -> false

    SessionPhase.Authenticated -> when {
        // Rule 4.
        resumedSessionId != null -> !transcriptSettled

        // Rule 3. A destination that exists is one the user put there.
        currentRoute != null && currentRoute != PabrikRoutes.SHELL -> false

        // Rules 2 and 3. The shell, or the frame before the shell exists.
        else -> !resumeDecided
    }
}

/** The gate itself: the app's own launch screen, held over the graph. */
@Composable
internal fun LaunchGateScreen(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(PabrikBackground)
            .testTag("launch_gate")
            .swallowTouches(),
    ) {
        AuthRestoringScreen()
    }
}

/** Consume every pointer event over this node, at the first pass, forever. */
private fun Modifier.swallowTouches(): Modifier = pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
        }
    }
}

package com.pabrik.mobile.network

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The back rule, and the shape of the fix that keeps a blank window unreachable. */
class PabrikNavGraphBackTest {

    @Test
    fun `a destination under the current one is popped onto`() {
        assertEquals(BackAction.PopPrevious, backActionFor(hasDestinationBelow = true))
    }

    @Test
    fun `nothing under the current one goes back to the shell instead of popping`() {
        // The graph alone underneath is what a `pabrik://` link that arrives without FLAG_ACTIVITY_NEW_TASK leaves behind: `handleDeepLink` navigates with popUpTo(graph …
        assertEquals(BackAction.ReturnToShell, backActionFor(hasDestinationBelow = false))
    }

    @Test
    fun `no back affordance pops unconditionally`() {
        val source = navGraphSource()
        // A bare `navController.popBackStack()` behind a back arrow is the defect itself; the guarded form inside `goBack` is the fix.
        assertEquals(
            "a back affordance must not call the inclusive pop unconditionally: at a " +
                "one-destination depth it empties the back stack and NavHost then " +
                "renders nothing at all",
            0,
            Regex("""onBack\s*=\s*\{\s*navController\.popBackStack\(\)\s*}""")
                .findAll(source)
                .count(),
        )
        // There is more than one place that pops to the shell now — the chat route's drawer switches chats in place as well as `goBack` rebuilding onto it — so the …
        assertEquals(
            "popping the shell inclusively is the blank-screen defect: the shell " +
                "is the one entry that has to survive",
            0,
            Regex("""popUpTo\(PabrikRoutes\.SHELL\)\s*\{\s*inclusive\s*=\s*true""")
                .findAll(source)
                .count(),
        )
        assertTrue(
            "the shell must stay reachable as the floor of the back stack",
            source.contains("popUpTo(PabrikRoutes.SHELL) { inclusive = false }"),
        )
    }

    @Test
    fun `an empty back stack is answered with a screen instead of nothing`() {
        val source = navGraphSource()
        assertTrue(
            "NavHost renders nothing for an empty back stack, so the graph has to " +
                "render something of its own when there is no visible destination",
            source.contains("visibleDestinations.isEmpty()") &&
                source.contains("NavigationLostScreen"),
        )
    }

    /** The module's own source, or null when the test runs from somewhere that cannot see it. */
    private fun navGraphSource(): String =
        sequenceOf(
            "src/main/java/com/pabrik/mobile/network/PabrikNavGraph.kt",
            "app/src/main/java/com/pabrik/mobile/network/PabrikNavGraph.kt",
        )
            .map(::File)
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("PabrikNavGraph.kt not reachable from ${File(".").absolutePath}")
}

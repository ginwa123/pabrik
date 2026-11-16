package com.pabrik.mobile.network

import android.content.Context
import androidx.navigation.NavGraph
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.ComposeNavigator
import androidx.navigation.compose.composable
import androidx.navigation.createGraph
import androidx.navigation.navArgument
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The blank screen, on a device, against the real `NavController`. */
@RunWith(AndroidJUnit4::class)
class NavControllerBackStackTest {

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    /** `NavController` is main-thread-confined — its lifecycle entries refuse to attach anywhere else — and the instrumentation thread is not the main thread, so … */
    private fun onMain(block: () -> Unit) =
        InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    /** The same routes the app declares, so what is under test is the real graph. */
    private fun controller(): NavHostController = NavHostController(context).apply {
        // What `rememberNavController` registers for us inside the composition.
        navigatorProvider.addNavigator(ComposeNavigator())
        graph = createGraph(startDestination = PabrikRoutes.SHELL) {
            composable(PabrikRoutes.SHELL) { }
            composable(
                route = PabrikRoutes.CHAT,
                arguments = listOf(
                    navArgument(PabrikRoutes.ARG_SESSION_ID) { type = NavType.StringType },
                ),
            ) { }
            composable(PabrikRoutes.NETWORK) { }
        }
    }

    /** Leaves a leaf as the *only* destination: navigate out to it, then drop the shell underneath. */
    private fun NavHostController.leaveOnlyTheLeaf(sessionId: String = "sess_1") {
        navigate(PabrikRoutes.chat(sessionId))
        popBackStack(PabrikRoutes.SHELL, inclusive = false)
    }

    /** True when only the graph sits under the current destination. */
    private fun NavHostController.isAtLeafDepth() =
        previousBackStackEntry == null || previousBackStackEntry!!.destination is NavGraph

    @Test
    fun theInclusivePopIsWhatEmptiesTheBackStack() = onMain {
        // The defect, stated as the library's own behaviour so the fix is anchored to something checkable rather than to a rendering.
        val controller = controller()
        controller.leaveOnlyTheLeaf()
        assertTrue(
            "precondition: the leaf is the only destination, with just the graph beneath",
            controller.isAtLeafDepth(),
        )

        controller.popBackStack()

        assertNull(
            "the no-argument popBackStack() is inclusive and dispatchOnDestinationChanged " +
                "drops the graph, so the controller is left with no destination — which is " +
                "what NavHost renders as nothing",
            controller.currentBackStackEntry,
        )
        // `visibleEntries` still holds the outgoing entry for the length of the exit transition, so the window keeps the screen it was leaving for a moment and then goes …
    }

    @Test
    fun backFromADeepLinkedLeafStillLeavesADestinationOnScreen() = onMain {
        val controller = controller()
        controller.leaveOnlyTheLeaf()
        assertTrue("precondition: the leaf is the only destination", controller.isAtLeafDepth())

        controller.goBackToPreviousOrShell()

        assertNotNull(
            "a back affordance must never leave the controller with nothing to draw",
            controller.currentBackStackEntry,
        )
        assertEquals(
            "and the reader is put back on the shell, not left on the leaf",
            PabrikRoutes.SHELL,
            controller.currentDestination?.route,
        )
        assertTrue(
            "so NavHost has something to draw",
            controller.visibleEntries.value.isNotEmpty(),
        )
    }

    @Test
    fun backFromTheNormalStackPopsOntoTheShell() = onMain {
        val controller = controller()
        controller.navigate(PabrikRoutes.chat("sess_1"))
        assertEquals(2, controller.visibleEntries.value.size)

        controller.goBackToPreviousOrShell()

        assertEquals(
            "the normal case still pops onto the shell rather than building a new stack",
            PabrikRoutes.SHELL,
            controller.currentDestination?.route,
        )
    }

    @Test
    fun backFromTheShellDoesNotEmptyTheBackStack() = onMain {
        val controller = controller()

        controller.goBackToPreviousOrShell()

        assertNotNull(
            "the shell is the floor: a back action there must not destroy the graph",
            controller.currentBackStackEntry,
        )
    }
}

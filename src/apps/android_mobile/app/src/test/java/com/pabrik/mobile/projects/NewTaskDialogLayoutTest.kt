package com.pabrik.mobile.projects

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import com.pabrik.mobile.ui.PabrikTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

/** The board's "New task" form, as a window. */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w411dp-h891dp")
class NewTaskDialogLayoutTest {

    @get:Rule
    val compose = createComposeRule()

    private var submitted: KanbanTaskForm? = null
    private var closed = false

    private fun render(
        isSubmitting: Boolean = false,
        errorMessage: String? = null,
    ) {
        compose.setContent {
            PabrikTheme {
                NewTaskDialog(
                    projectName = "sprint board",
                    defaultCwd = "/home/ginwa/ginwaaitoolbox",
                    data = NewTaskDialogData(
                        columns = listOf(KanbanColumn("col-1", "todo", 0)),
                    ),
                    isSubmitting = isSubmitting,
                    errorMessage = errorMessage,
                    onSubmit = { submitted = it },
                    onClose = { closed = true },
                )
            }
        }
    }

    /** The regression itself, stated as the cause rather than the symptom. */
    @Test
    fun the_form_does_not_open_a_platform_dialog_window() {
        render()

        assertNull(
            "the form must be drawn in the activity's composition, not a Dialog " +
                "window — see the class doc for why that word is load-bearing",
            ShadowDialog.getLatestDialog(),
        )
    }

    /** "Where is the Run agent button?" — the complaint this fixes. */
    @Test
    fun the_commit_row_sits_inside_the_window_with_room_to_spare() {
        render()

        val root = compose.onRoot().getUnclippedBoundsInRoot()
        val commit = compose.onNodeWithTag("create_task_create_and_run")
            .getUnclippedBoundsInRoot()

        assertTrue(
            "commit row starts at $commit but the form is $root",
            commit.left >= root.left && commit.right <= root.right,
        )
        assertTrue(
            "commit row runs off the bottom of the window: $commit in $root",
            commit.bottom <= root.bottom,
        )
        compose.onNodeWithTag("create_task_create_and_run").assertIsDisplayed()
    }

    /** The button stays disabled until there is something to create, then arms. */
    @Test
    fun the_run_agent_button_arms_once_the_form_has_a_name() {
        render()

        compose.onNodeWithTag("create_task_create_and_run").assertIsNotEnabled()
        compose.onNodeWithTag("create_task_name").performTextInput("ship the drawer")
        compose.waitForIdle()

        compose.onNodeWithTag("create_task_create_and_run").assertIsEnabled()
        compose.onNodeWithTag("create_task_create_and_run")
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()

        assertEquals(true, submitted?.runAgent)
        assertEquals("ship the drawer", submitted?.name)
    }

    /** The caret's "Create task only" is the other half of the split button. */
    @Test
    fun the_caret_offers_create_task_only() {
        render()

        compose.onNodeWithTag("create_task_name").performTextInput("just a card")
        compose.waitForIdle()
        compose.onNodeWithTag("create_task_commit_menu").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("create_task_create_only").performClick()
        compose.waitForIdle()

        assertEquals(false, submitted?.runAgent)
    }

    @Test
    fun back_and_close_both_leave_the_form() {
        render()

        compose.onNodeWithTag("create_task_back").performClick()
        compose.waitForIdle()

        assertTrue("Back must leave the form now that it owns the window", closed)
    }

    /** A failed create keeps the form open with what was typed still in it, and the banner has to stay above the scroll rather than at the bottom of it. */
    @Test
    fun a_failed_create_keeps_the_form_open_with_its_error_visible() {
        render(errorMessage = "The server refused the create.")

        compose.onNodeWithTag("create_task_error").assertIsDisplayed()
        compose.onNodeWithTag("create_task_name").assertIsDisplayed()
        assertTrue("a failed create must not close the form", !closed)
    }
}
